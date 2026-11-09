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
    var isRefreshing = false
    var isOffline = false
    var lastError: String?
    var undo: UndoAction?
    var composerText = ""
    /// 바뀔 때마다 입력 바에 포커스를 준다 (딥링크·단축키·제어 위젯).
    var composerFocusRequest = 0
    var showsSettings = false

    /// 체크 직후 0.8초 동안 목록에 남겨 둘 항목 (실행 취소 구간).
    private var lingering: Set<String> = []
    private var removalTasks: [String: Task<Void, Never>] = [:]
    private var pendingTrash: [String: Task<Void, Never>] = [:]

    init(services: TodoServices = .shared) {
        self.services = services
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
        if let id = await repository.defaultViewId() {
            await open(viewId: id)
            phase = .ready
            await refreshCatalog()
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

    func becameActive() async {
        guard phase == .ready else { return }
        await refresh()
    }

    // MARK: 뷰

    func refreshCatalog() async {
        do {
            catalog = try await repository.catalog(refresh: true)
        } catch {
            handle(error)
        }
    }

    func open(viewId: String) async {
        currentViewId = viewId
        await repository.rememberLastView(viewId)
        currentView = await repository.store.view(viewId)
        if let cached = await repository.cachedItems(viewId) { items = cached.items } else { items = [] }
        await refresh()
    }

    func refresh() async {
        guard let viewId = currentViewId else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snapshot = try await repository.fetchItems(viewId)
            currentView = await repository.store.view(viewId)
            guard currentViewId == viewId else { return }
            items = snapshot.items
            isOffline = false
            lastError = nil
        } catch {
            handle(error)
        }
        reloadWidgets()
    }

    /// 화면에 보여줄 순서: 안 한 일 먼저, 체크한 일(완료로 거르지 않는 뷰에서 남는 것)은 아래로.
    var displayItems: [TodoItem] {
        let filtersByCompletion = currentView?.filtersByCompletion ?? true
        let showsDone = currentView?.showsDone ?? false
        let visible = items.filter { item in
            guard filtersByCompletion else { return true }
            let belongs = item.isDone == showsDone
            return belongs || lingering.contains(item.id)
        }
        if filtersByCompletion { return visible }
        return visible.enumerated().sorted { a, b in
            a.element.isDone == b.element.isDone ? a.offset < b.offset : !a.element.isDone
        }.map(\.element)
    }

    var isWritable: Bool { currentView?.completion.isWritable ?? false }

    var currentSummary: ViewSummary? { catalog.first { $0.id == currentViewId } ?? currentView?.summary }

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
            withAnimation(Motion.check) { _ = self?.lingering.remove(item.id) }
        }
        undo = UndoAction(message: done ? String(localized: "Checked “\(item.title)”") : String(localized: "Unchecked")) {
            [weak self] in
            self?.undo = nil
            if let current = self?.items.first(where: { $0.id == item.id }) { self?.toggle(current) }
        }
        scheduleUndoDismiss()
        Task {
            do {
                try await repository.setDone(viewId: viewId, itemId: item.id, done: done)
                markSettled(item.id)
            } catch {
                handle(error)
            }
            reloadWidgets()
        }
    }

    func add() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let viewId = currentViewId else { return }
        composerText = ""
        let placeholder = TodoItem(id: "draft-\(UUID().uuidString)", title: text, isDone: currentView?.showsDone ?? false, isPending: true)
        withAnimation(Motion.check) { items.insert(placeholder, at: 0) }
        Task {
            do {
                try await repository.add(viewId: viewId, title: text)
                if let cached = await repository.cachedItems(viewId), currentViewId == viewId {
                    withAnimation(Motion.check) { items = cached.items }
                }
            } catch {
                items.removeAll { $0.id == placeholder.id }
                handle(error)
            }
            reloadWidgets()
        }
    }

    func rename(_ item: TodoItem, to title: String) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let viewId = currentViewId, !text.isEmpty, text != item.title,
            let index = items.firstIndex(where: { $0.id == item.id })
        else { return }
        items[index].title = text
        items[index].isPending = true
        Task {
            do {
                try await repository.rename(viewId: viewId, itemId: item.id, title: text)
                markSettled(item.id)
            } catch {
                handle(error)
            }
            reloadWidgets()
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
            self.reloadWidgets()
        }
        undo = UndoAction(message: String(localized: "Deleted “\(item.title)”")) { [weak self] in
            guard let self else { return }
            self.pendingTrash[item.id]?.cancel()
            self.pendingTrash[item.id] = nil
            withAnimation(Motion.check) { self.items.insert(removed, at: min(index, self.items.count)) }
            self.undo = nil
        }
        scheduleUndoDismiss()
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
        reloadWidgets()
    }

    func finishOnboarding(viewId: String) async {
        await open(viewId: viewId)
        phase = .ready
        await refreshCatalog()
        reloadWidgets()
    }

    func signOut() async {
        await repository.signOut()
        credentials = nil
        catalog = []
        items = []
        currentViewId = nil
        currentView = nil
        phase = .onboarding
        reloadWidgets()
    }

    // MARK: 오류

    func handle(_ error: Error) {
        switch error {
        case let error as NotionError where error.isOffline:
            isOffline = true
        case NotionError.unauthorized:
            lastError = String(localized: "Your Notion connection expired. Sign in again.")
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

    func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
