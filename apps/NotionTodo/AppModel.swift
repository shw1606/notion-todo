import DesignSystem
import Foundation
import NotionKit
import Observation
import SwiftUI
import TodoCore
import WidgetKit

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case onboarding
        case ready
    }

    struct UndoAction: Identifiable {
        let id = UUID()
        var message: String
        var perform: @MainActor () -> Void
    }

    let services: TodoServices
    var repository: TodoRepository { services.repository }

    var phase: Phase = .launching
    var credentials: Credentials?
    var catalog: [ViewSummary] = []
    var currentViewId: String?
    var currentView: ResolvedView?
    var items: [TodoItem] = []
    /// 지금 뷰의 로컬 배치(순서·섹션). 이 기기에만 저장한다.
    var layout = ViewLayout()
    /// 이름을 고치는 중인 섹션. 새 섹션을 만들면 바로 이름을 적게 한다.
    var editingSectionId: UUID?
    var isRefreshing = false
    var isOffline = false
    var lastError: String?
    /// Notion이 연결을 끊었다(토큰 취소·만료). 온보딩 첫 화면에서 다시 연결하게 한다.
    var needsReconnect = false
    /// 연결될 때마다 늘어난다. 온보딩 화면은 이것을 보고 다음 단계로 넘어간다.
    private(set) var signIns = 0
    /// 브라우저 탭에서 돌아온 연결의 끝 (성공·취소·실패). 화면은 바뀔 때마다 기다림을 푼다.
    private(set) var browserSignInOutcome: BrowserSignInOutcome?

    struct BrowserSignInOutcome: Equatable {
        let id = UUID()
        /// 실패했을 때만. 취소는 nil.
        var error: String?
    }
    var undo: UndoAction?
    var composerText = ""
    /// 바뀔 때마다 입력 바에 포커스를 준다 (딥링크·단축키·제어 위젯).
    var composerFocusRequest = 0
    var showsSettings = false
    var showsAddDatabase = false

    /// 체크 직후 0.8초 동안 목록에 남겨 둘 항목 (실행 취소 구간).
    private var lingering: Set<String> = []
    private var removalTasks: [String: Task<Void, Never>] = [:]
    private var pendingTrash: [String: Task<Void, Never>] = [:]

    var lastFetchedAt: Date?

    /// 자기가 보는 뷰를 따로 기억하는 모델(떠 있는 메모)이면 그 UserDefaults 키. nil이면 창들이 같이 쓰는
    /// "마지막으로 연 뷰"를 따른다.
    private let ownViewKey: String?

    init(services: TodoServices = .shared, ownViewKey: String? = nil) {
        self.services = services
        self.ownViewKey = ownViewKey
        // 다른 창(또는 메뉴 막대·설정 창·떠 있는 메모)에서 로그인·로그아웃하면 이 창도 다시 시작하고, DB를 더하거나 빼면
        // 목록을, 항목이나 배치를 바꾸면 그것을 캐시에서 다시 읽는다.
        observers = [
            observe(.notionTodoSessionChanged) { await $0.start() },
            observe(.notionTodoCatalogChanged) { await $0.reloadCatalog() },
            observe(.notionTodoLayoutChanged) { await $0.reloadLayout() },
            observe(.notionTodoItemsChanged) { await $0.reloadItems() },
        ]
    }

    private var observers: [Task<Void, Never>] = []

    isolated deinit {
        for observer in observers { observer.cancel() }
    }

    private func observe(_ name: Notification.Name, _ action: @escaping @MainActor (AppModel) async -> Void)
        -> Task<Void, Never>
    {
        Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: name) {
                guard let self, note.object as AnyObject? !== self else { continue }
                await action(self)
            }
        }
    }

    private func broadcastSessionChange() {
        NotificationCenter.default.post(name: .notionTodoSessionChanged, object: self)
    }

    var isOAuthAvailable: Bool { services.configuration.oauth != nil }

    // MARK: 시작

    func start() async {
        credentials = await services.auth.credentials
        guard credentials != nil else {
            phase = .onboarding
            return
        }
        catalog = await repository.cachedCatalog()
        if let id = await initialViewId() {
            await showCached(id)
            phase = .ready
            await refresh()
            await renewLockScreenCard()
            if ownViewKey == nil {
                await refreshCatalog()
            } else if let fresh = try? await repository.catalog() {
                // 창 옆에 사는 모델은 뷰 목록이 낡았을 때만 다시 받는다. 창이 받아 오면 알림으로 같이 바뀐다.
                catalog = fresh
            }
        } else {
            await refreshCatalog()
            if let id = catalog.preferredDefault?.id {
                await open(viewId: id)
                phase = .ready
            } else {
                phase = .onboarding
            }
        }
    }

    /// 처음 보여 줄 뷰. 자기 뷰를 기억하는 모델은 그 뷰가 아직 고른 DB 안에 있을 때만 그것으로 연다.
    private func initialViewId() async -> String? {
        if let ownViewKey, let id = UserDefaults.standard.string(forKey: ownViewKey),
            catalog.contains(where: { $0.id == id })
        {
            return id
        }
        return await repository.defaultViewId()
    }

    func becameActive() async {
        guard phase == .ready else { return }
        await refresh()
        await renewLockScreenCard()
    }

    /// 앱이 앞에 왔다 → 잠금 화면 카드를 새로 띄우거나(없을 때·오래 떠 있었을 때) 내용을 맞춘다 (iPhone·iPad).
    /// 카드의 뷰가 지금 보는 뷰와 다르면 그 뷰도 받아 온다.
    private func renewLockScreenCard() async {
        #if os(iOS)
            guard ownViewKey == nil, LockScreenCard.isOn else { return }
            let cardViewId = await LockScreenCard.viewId()
            await LockScreenCard.sync(
                start: .ifOlderThan(LockScreenCard.renewInApp), fetch: cardViewId != currentViewId || isOffline)
            LockScreenCard.scheduleRefresh()
        #endif
    }

    // MARK: 뷰

    func refreshCatalog() async {
        do {
            let shown = catalog
            catalog = try await repository.catalog(refresh: true)
            // Notion에서 뷰가 늘거나 이름이 바뀌었다 → 다른 창·떠 있는 메모의 뷰 메뉴도 캐시에서 다시 읽게 한다.
            if catalog != shown { NotificationCenter.default.post(name: .notionTodoCatalogChanged, object: self) }
        } catch {
            handle(error)
        }
    }

    /// 고른 DB와 그 뷰, 고른 순서대로 (사이드바·설정).
    var databases: [DatabaseViews] { catalog.byDatabase }

    /// "DB 추가"로 고른 DB의 할 일 뷰를 연다.
    func didAddDatabase(viewId: String) async {
        catalog = await repository.cachedCatalog()
        NotificationCenter.default.post(name: .notionTodoCatalogChanged, object: self)
        await open(viewId: viewId)
        reloadWidgets()
    }

    /// 목록에서 뺀다. Notion의 DB는 그대로 둔다. 하나 남은 DB는 뺄 수 없다.
    func removeDatabase(_ dataSourceId: String) async {
        guard databases.count > 1 else { return }
        await repository.removeDatabase(dataSourceId)
        await reloadCatalog()
        NotificationCenter.default.post(name: .notionTodoCatalogChanged, object: self)
        reloadWidgets()
    }

    /// 캐시된 목록을 다시 읽는다. 보던 뷰의 DB가 빠졌으면 남은 DB의 할 일 뷰로 옮긴다.
    private func reloadCatalog() async {
        catalog = await repository.cachedCatalog()
        guard phase == .ready, let id = currentViewId, !catalog.contains(where: { $0.id == id }),
            let next = catalog.preferredDefault
        else { return }
        await open(viewId: next.id)
    }

    func open(viewId: String) async {
        await showCached(viewId)
        await refresh()
    }

    /// 네트워크를 기다리지 않고 마지막 캐시로 먼저 그린다.
    private func showCached(_ viewId: String) async {
        let isSameView = currentViewId == viewId
        currentViewId = viewId
        if let ownViewKey {
            UserDefaults.standard.set(viewId, forKey: ownViewKey)
        } else {
            await repository.rememberLastView(viewId)
        }
        let view = await repository.store.view(viewId)
        let cached = await repository.cachedItems(viewId)?.items ?? []
        let stored = await repository.layout(viewId)
        guard currentViewId == viewId else { return }
        currentView = view
        items = cached
        // 같은 뷰에 저장 중인 변경이 있으면 그 저장이 끝날 때 맞춘다 (`changeLayout`).
        if !isSameView || layoutWrites == 0 { layout = stored }
        if !isSameView { editingSectionId = nil }
    }

    func refresh() async {
        guard let viewId = currentViewId else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let shown = items
        let wasOffline = isOffline
        do {
            let snapshot = try await repository.fetchItems(viewId)
            currentView = try await repository.resolvedView(viewId)
            guard currentViewId == viewId else { return }
            items = withoutPendingTrash(snapshot.items)
            lastFetchedAt = snapshot.fetchedAt
            isOffline = false
            lastError = nil
            // 조회하면서 저장소가 배치를 고쳤을 수 있다 (오프라인으로 만든 항목의 ID 바뀜, 사라진 항목 정리).
            await reloadLayout()
            // 위젯과 다른 창은 같은 캐시를 읽는다. 달라진 게 없으면 다시 그리게 하지 않는다: 다시 그릴 때마다 위젯 확장이
            // 떠서 Notion을 한 번 더 조회한다 (앱을 앞으로 가져올 때마다 일어나던 일).
            if items != shown || wasOffline {
                itemsDidChange()
            } else {
                // 달라진 게 없어도 잠금 화면 카드에는 방금 받아 왔다는 것을 알린다 (카드는 오래된 내용에 시각을 적는다).
                #if os(iOS)
                    Task { await LockScreenCard.sync() }
                #endif
            }
        } catch {
            handle(error)
            // 오프라인이면 위젯도 보여 줄 새 내용이 없다. 그 밖의 오류(연결 끊김 등)는 위젯 안내가 바뀐다.
            if (error as? NotionError)?.isOffline != true { reloadWidgets() }
        }
    }

    /// 목록에 그릴 줄: 섹션 밖 항목 → 섹션(머리·항목) 순, 사용자가 정한 순서대로.
    /// 완료로 거르지 않는 뷰에서 남는 체크한 일은 묶음 안에서 아래로 내린다.
    var rows: [LayoutRow] {
        let filtersByCompletion = currentView?.filtersByCompletion ?? true
        let showsDone = currentView?.showsDone ?? false
        let visible = items.filter { item in
            guard filtersByCompletion else { return true }
            let belongs = item.isDone == showsDone
            return belongs || lingering.contains(item.id)
        }
        return layout.rows(for: visible, doneLast: !filtersByCompletion)
    }

    /// 화면에 보이는 항목만, 보이는 순서대로 (메뉴 막대 빠른 기록).
    var displayItems: [TodoItem] { rows.compactMap(\.item) }

    var isWritable: Bool { currentView?.completion.isWritable ?? false }

    var currentSummary: ViewSummary? { catalog.first { $0.id == currentViewId } ?? currentView?.summary }

    // MARK: 순서·섹션 (이 기기에만 저장, Notion에는 보내지 않는다)

    /// 아직 저장소에 반영 중인 배치 변경 수.
    private var layoutWrites = 0

    /// 화면의 배치를 바로 바꾸고, 같은 변경을 저장소(App Group 파일)에도 적용한다.
    private func changeLayout(_ change: @escaping @Sendable (inout ViewLayout) -> Void) {
        guard let viewId = currentViewId else { return }
        change(&layout)
        layoutWrites += 1
        Task {
            let stored = await repository.updateLayout(viewId, change)
            layoutWrites -= 1
            // 저장소 쪽이 기준이다 (위젯 확장이 그사이 항목 ID를 바꿨을 수 있다).
            if layoutWrites == 0, currentViewId == viewId { layout = stored }
            NotificationCenter.default.post(name: .notionTodoLayoutChanged, object: self)
            reloadWidgets()
        }
    }

    /// 다른 창이 배치를 바꿨거나 저장소가 고쳤을 때 다시 읽는다.
    private func reloadLayout() async {
        guard let viewId = currentViewId, layoutWrites == 0 else { return }
        let stored = await repository.layout(viewId)
        if currentViewId == viewId, layoutWrites == 0 { layout = stored }
    }

    /// 목록에서 줄을 끌어 옮겼다.
    func moveRows(from source: IndexSet, to destination: Int) {
        let rows = self.rows
        changeLayout { $0.move(rows: rows, fromOffsets: source, toOffset: destination) }
    }

    /// 항목을 섹션으로 보낸다. nil이면 섹션 밖으로.
    func move(_ item: TodoItem, toSection sectionId: UUID?) {
        let visibleIds = rows.compactMap { $0.item?.id }
        withAnimation(Motion.preferred) {
            changeLayout { $0.move(itemId: item.id, toSection: sectionId, visibleIds: visibleIds) }
        }
    }

    /// 목록 맨 아래에 새 섹션을 만들고 바로 이름을 적게 한다. 이름을 적지 않으면 "새 섹션"으로 보인다 (`displayTitle`).
    func addSection() {
        let section = LayoutSection(title: "", tint: layout.nextTint)
        // 줄을 넣기 전에 정한다. 넣은 뒤에 정하면 iPad에서는 새 줄이 이미 그려진 뒤라 입력란으로 바뀌지 않는다.
        editingSectionId = section.id
        withAnimation(Motion.preferred) {
            changeLayout { $0.sections.append(section) }
        }
    }

    func renameSection(_ id: UUID, to title: String) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        changeLayout { $0.updateSection(id, title: text) }
    }

    func setTint(_ tint: SectionTint, forSection id: UUID) {
        changeLayout { $0.updateSection(id, tint: tint) }
    }

    func moveSection(_ id: UUID, by offset: Int) {
        withAnimation(Motion.preferred) {
            changeLayout { $0.moveSection(id, by: offset) }
        }
    }

    /// 섹션만 없앤다. 담겨 있던 항목은 섹션 밖으로 나온다.
    func removeSection(_ id: UUID) {
        if editingSectionId == id { editingSectionId = nil }
        withAnimation(Motion.preferred) {
            changeLayout { $0.removeSection(id) }
        }
    }

    /// 사용자가 정한 순서와 Notion 뷰의 정렬이 다르다.
    var canResetOrder: Bool {
        var reset = layout
        reset.resetOrder(notionOrder: items.map(\.id))
        return reset != layout
    }

    /// 정한 순서를 버리고 Notion 뷰의 정렬로 돌아간다. 섹션은 그대로 둔다.
    func resetOrder() {
        let notionOrder = items.map(\.id)
        withAnimation(Motion.preferred) {
            changeLayout { $0.resetOrder(notionOrder: notionOrder) }
        }
    }

    // MARK: 쓰기

    func toggle(_ item: TodoItem) {
        guard isWritable, let viewId = currentViewId, let index = items.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        let done = !item.isDone
        items[index].isDone = done
        items[index].isPending = true
        // 이 뷰에서 빠질 항목이면 0.8초 남겨 두었다가 뺀다.
        lingering.insert(item.id)
        removalTasks[item.id]?.cancel()
        removalTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(for: Motion.removalDelay)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.preferred) { _ = self?.lingering.remove(item.id) }
            self?.removalTasks[item.id] = nil
        }
        undo = UndoAction(message: done ? String(localized: "Checked “\(item.title)”") : String(localized: "Unchecked")) {
            [weak self] in
            self?.undo = nil
            if let current = self?.items.first(where: { $0.id == item.id }) { self?.toggle(current) }
        }
        scheduleUndoDismiss()
        itemWrites += 1
        Task {
            do {
                try await repository.setDone(viewId: viewId, itemId: item.id, done: done)
                markSettled(item.id)
            } catch {
                handle(error)
            }
            finishItemWrite()
        }
    }

    func add() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let viewId = currentViewId else { return }
        composerText = ""
        let placeholder = TodoItem(id: "draft-\(UUID().uuidString)", title: text, isDone: currentView?.showsDone ?? false, isPending: true)
        withAnimation(Motion.preferred) { items.insert(placeholder, at: 0) }
        itemWrites += 1
        Task {
            do {
                try await repository.add(viewId: viewId, title: text)
                if let cached = await repository.cachedItems(viewId), currentViewId == viewId {
                    withAnimation(Motion.preferred) { items = withoutPendingTrash(cached.items) }
                    await reloadLayout()
                }
            } catch {
                items.removeAll { $0.id == placeholder.id }
                handle(error)
            }
            finishItemWrite()
        }
    }

    func rename(_ item: TodoItem, to title: String) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let viewId = currentViewId, !text.isEmpty, text != item.title,
            let index = items.firstIndex(where: { $0.id == item.id })
        else { return }
        items[index].title = text
        items[index].isPending = true
        itemWrites += 1
        Task {
            do {
                try await repository.rename(viewId: viewId, itemId: item.id, title: text)
                markSettled(item.id)
            } catch {
                handle(error)
            }
            finishItemWrite()
        }
    }

    /// 목록에서 바로 빼고, 실행 취소 구간(4초)이 지나면 Notion 휴지통으로 보낸다.
    func trash(_ item: TodoItem) {
        guard let viewId = currentViewId, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let removed = items.remove(at: index)
        pendingTrash[item.id]?.cancel()
        pendingTrash[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.pendingTrash[item.id] = nil
            do {
                try await self.repository.trash(viewId: viewId, itemId: item.id)
            } catch {
                self.handle(error)
            }
            self.itemsDidChange()
        }
        undo = UndoAction(message: String(localized: "Deleted “\(item.title)”")) { [weak self] in
            guard let self else { return }
            self.pendingTrash[item.id]?.cancel()
            self.pendingTrash[item.id] = nil
            withAnimation(Motion.preferred) { self.items.insert(removed, at: min(index, self.items.count)) }
            self.undo = nil
        }
        scheduleUndoDismiss()
    }

    // MARK: 다른 창과 맞추기

    /// 저장소에 보내는 중인 항목 변경 수. 그동안은 다른 창의 변경으로 캐시를 다시 읽지 않는다
    /// (방금 한 체크가 아직 대기열에 없으면 되돌아가 보인다). 끝나면 밀린 것을 한 번 읽는다.
    private var itemWrites = 0
    private var missedItemChange = false

    private func finishItemWrite() {
        itemWrites -= 1
        itemsDidChange()
        if itemWrites == 0, missedItemChange {
            missedItemChange = false
            Task { await reloadItems() }
        }
    }

    /// 이 모델에서 항목이 바뀌었다. 위젯과, 같은 캐시를 읽는 다른 창(메뉴 막대·떠 있는 메모)이 다시 그리게 한다.
    private func itemsDidChange() {
        NotificationCenter.default.post(name: .notionTodoItemsChanged, object: self)
        reloadWidgets()
    }

    /// 다른 창이 항목을 바꿨거나 새로 받아 왔다 → 네트워크 없이 캐시에서 다시 읽는다.
    private func reloadItems() async {
        guard phase == .ready, let viewId = currentViewId else { return }
        guard itemWrites == 0 else {
            missedItemChange = true
            return
        }
        guard let cached = await repository.cachedItems(viewId), currentViewId == viewId, itemWrites == 0 else { return }
        let fresh = withoutPendingTrash(cached.items)
        if fresh != items { withAnimation(Motion.preferred) { items = fresh } }
        await reloadLayout()
    }

    /// 지우는 중(실행 취소 구간)인 항목은 캐시에 아직 있어도 보이지 않게 한다.
    private func withoutPendingTrash(_ list: [TodoItem]) -> [TodoItem] {
        pendingTrash.isEmpty ? list : list.filter { pendingTrash[$0.id] == nil }
    }

    private func markSettled(_ id: String) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].isPending = false }
    }

    private var undoDismissTask: Task<Void, Never>?
    private func scheduleUndoDismiss() {
        undoDismissTask?.cancel()
        let current = undo?.id
        undoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self?.undo?.id == current else { return }
            withAnimation { self?.undo = nil }
        }
    }

    func requestComposerFocus() {
        composerFocusRequest += 1
    }

    // MARK: 딥링크

    func handle(url: URL) {
        if url.scheme == OAuthConfig.callbackScheme, url.host() == "oauth" {
            Task { await finishBrowserSignIn(callback: url) }
            return
        }
        guard let action = DeepLink.parse(url) else { return }
        switch action {
        case .compose(let viewId):
            if let viewId, viewId != currentViewId { Task { await open(viewId: viewId) } }
            requestComposerFocus()
        case .view(let id):
            Task { await open(viewId: id) }
        case .onboarding:
            if credentials == nil { phase = .onboarding }
        }
    }

    // MARK: 계정

    func didSignIn(_ credentials: Credentials) async {
        self.credentials = credentials
        needsReconnect = false
        lastError = nil
        signIns += 1
        reloadWidgets()
    }

    /// 기본 브라우저 탭에서 진행 중인 "Notion 연결하기"(Mac). 결과는 앱 주소로 돌아오고,
    /// 연결을 시작한 창(설정 창일 수도 있다)과 상관없이 주소를 받은 창이 이것으로 마친다.
    static var pendingBrowserSignIn: PKCE?

    func finishBrowserSignIn(callback: URL) async {
        guard let pkce = Self.pendingBrowserSignIn else { return }
        Self.pendingBrowserSignIn = nil
        do {
            await didSignIn(try await services.auth.completeSignIn(callback: callback, pkce: pkce))
            browserSignInOutcome = BrowserSignInOutcome()
            // 설정의 "페이지 더 고르기"로 돌아온 경우: 이 창의 목록도 다시 받는다 (다른 창은 알림을 받고 다시 시작한다).
            if phase == .ready { await refreshCatalog() }
            broadcastSessionChange()
        } catch AuthError.canceled {
            browserSignInOutcome = BrowserSignInOutcome()
        } catch {
            browserSignInOutcome = BrowserSignInOutcome(error: ConnectionError.message(for: error))
        }
    }

    /// 읽기 전용 뷰에서 점을 누르면 이유를 알려준다.
    func explainReadOnly() {
        lastError = String(localized: "This view can’t be checked off from here.")
    }

    func finishOnboarding(viewId: String) async {
        await showCached(viewId)
        phase = .ready
        await refresh()
        await refreshCatalog()
        reloadWidgets()
        broadcastSessionChange()
    }

    func signOut() async {
        await repository.signOut()
        credentials = nil
        catalog = []
        items = []
        layout = ViewLayout()
        editingSectionId = nil
        currentViewId = nil
        currentView = nil
        phase = .onboarding
        reloadWidgets()
        broadcastSessionChange()
    }

    // MARK: 오류

    func handle(_ error: Error) {
        switch error {
        case let error as NotionError where error.isOffline:
            isOffline = true
        case NotionError.unauthorized:
            lastError = String(localized: "Your Notion connection expired. Sign in again.")
            needsReconnect = true
            phase = .onboarding
        case NotionError.notFound:
            lastError = String(localized: "This view is no longer available. Choose another one.")
        case TodoError.readOnly:
            lastError = String(localized: "This view can’t be checked off from here.")
        case NotionError.rateLimited:
            lastError = String(localized: "Notion is busy. Trying again shortly.")
        default:
            lastError = error.localizedDescription
        }
    }

    /// 같은 캐시를 읽는 위젯과 잠금 화면 카드를 다시 그리게 한다.
    func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
        #if os(iOS)
            Task { await LockScreenCard.sync() }
        #endif
    }
}

extension Notification.Name {
    static let notionTodoSessionChanged = Notification.Name("NotionTodoSessionChanged")
    static let notionTodoCatalogChanged = Notification.Name("NotionTodoCatalogChanged")
    static let notionTodoLayoutChanged = Notification.Name("NotionTodoLayoutChanged")
    // `notionTodoItemsChanged`는 Shared/LockScreenCard.swift에 있다 (카드의 체크 인텐트도 보낸다).
}
