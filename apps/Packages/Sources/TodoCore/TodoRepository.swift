import Foundation
import NotionKit

/// 앱·위젯·인텐트가 공유하는 데이터 창구. 쓰기는 먼저 캐시에 반영(낙관적)하고 대기열을 거쳐 Notion에 보낸다.
public actor TodoRepository {
    public let client: NotionClient
    public let store: SharedStore
    public let auth: AuthSession
    let viewMaxAge: TimeInterval
    private var isFlushing = false

    public init(client: NotionClient, store: SharedStore, auth: AuthSession, viewMaxAge: TimeInterval = 6 * 3600) {
        self.client = client
        self.store = store
        self.auth = auth
        self.viewMaxAge = viewMaxAge
    }

    // MARK: 고른 DB

    /// 앱 목록·위젯 설정에 올릴 DB (data source ID), 고른 순서대로. 연결이 볼 수 있는 DB 전부가 아니라
    /// 온보딩·"DB 추가"로 고른 것만 올린다.
    public func databaseIds() -> [String] {
        let settings = store.settings()
        if let ids = settings.databaseIds { return ids }
        // 고른 DB를 기록하기 전 버전에서 올라왔다: 마지막으로 연 뷰의 DB만 남긴다.
        let ids = settings.lastViewId.flatMap { store.view($0) }.map { [$0.dataSourceId] } ?? []
        saveDatabaseIds(ids)
        return ids
    }

    func saveDatabaseIds(_ ids: [String]) {
        var settings = store.settings()
        settings.databaseIds = ids
        try? store.save(settings: settings)
    }

    func isChosen(_ dataSourceId: String) -> Bool {
        databaseIds().contains { NotionID.compact($0) == NotionID.compact(dataSourceId) }
    }

    /// 목록에서 뺀다. Notion의 DB는 그대로 둔다.
    public func removeDatabase(_ dataSourceId: String) {
        saveDatabaseIds(databaseIds().filter { NotionID.compact($0) != NotionID.compact(dataSourceId) })
    }

    // MARK: 뷰 목록

    /// 고른 DB의 목록형 뷰. 각 뷰를 해석해 캐시에 넣는다. 휴지통에 있거나 연결에서 빠진 DB는 고른 목록에서도 뺀다.
    public func catalog(refresh: Bool = false) async throws -> [ViewSummary] {
        if !refresh, let cached = store.catalog(), Date.now.timeIntervalSince(cached.fetchedAt) < viewMaxAge {
            return cachedCatalog()
        }
        let ids = databaseIds()
        let found = try await Self.listableViews(ofDataSources: ids, client: client)
        let gone = Set(zip(ids, found).filter { $0.1 == nil }.map { NotionID.compact($0.0) })
        if !gone.isEmpty { saveDatabaseIds(databaseIds().filter { !gone.contains(NotionID.compact($0)) }) }
        let views = found.compactMap { $0 }.flatMap { $0 }
        for view in views { try? store.save(view: view) }
        // 받는 동안 "DB 추가"로 더한 DB의 뷰는 그대로 둔다. 뺀 DB의 뷰는 버린다.
        let fetched = Set(ids.map(NotionID.compact))
        let chosen = Set(databaseIds().map(NotionID.compact))
        let added = (store.catalog()?.views ?? []).filter {
            let id = NotionID.compact($0.dataSourceId)
            return chosen.contains(id) && !fetched.contains(id)
        }
        try? store.save(catalog: ViewCatalog(views: views.map(\.summary) + added, fetchedAt: .now))
        return cachedCatalog()
    }

    /// DB 순서를 지키며 3개씩 동시에 받는다 (Notion 요청 한도는 평균 초당 3회).
    /// 휴지통에 있거나 연결에서 빠진 DB 자리는 nil.
    static func listableViews(ofDataSources ids: [String], client: NotionClient) async throws -> [[ResolvedView]?] {
        try await withThrowingTaskGroup(of: (Int, [ResolvedView]?).self) { group in
            var results = [[ResolvedView]?](repeating: nil, count: ids.count)
            var next = 0
            func enqueue() {
                guard next < ids.count else { return }
                let index = next
                next += 1
                group.addTask { (index, try await listableViews(ofDataSource: ids[index], client: client)) }
            }
            for _ in 0..<3 { enqueue() }
            while let (index, views) = try await group.next() {
                results[index] = views
                enqueue()
            }
            return results
        }
    }

    static func listableViews(ofDataSource id: String, client: NotionClient) async throws -> [ResolvedView]? {
        let source: DataSource
        do {
            source = try await client.dataSource(id)
        } catch NotionError.notFound {
            return nil
        }
        guard source.inTrash != true else { return nil }
        return try await listableViews(of: source, client: client)
    }

    /// DB 하나의 목록형 뷰(표·목록·보드…)를 해석한다.
    static func listableViews(of source: DataSource, client: NotionClient) async throws -> [ResolvedView] {
        var views: [ResolvedView] = []
        for viewId in try await client.viewIds(dataSourceId: source.id) {
            let view = try await client.view(viewId)
            if view.isListable { views.append(ViewResolver.resolve(view: view, schema: source)) }
        }
        return views
    }

    /// 고른 DB의 뷰를 더한다 (온보딩·"DB 추가"). 전체 목록을 다시 받기 전에도 사이드바·위젯 설정에 보인다.
    /// 받은 시각은 그대로 둬서 다음에 전체 목록을 받게 한다.
    func addToCatalog(_ views: [ViewSummary]) {
        var ids = databaseIds()
        for view in views where !ids.contains(where: { NotionID.compact($0) == NotionID.compact(view.dataSourceId) }) {
            ids.append(view.dataSourceId)
        }
        saveDatabaseIds(ids)
        // 같은 DB의 예전 뷰(그사이 Notion에서 지운 뷰 포함)는 새로 받은 것으로 바꾼다.
        let cached = store.catalog()
        let sources = Set(views.map { NotionID.compact($0.dataSourceId) })
        let merged = (cached?.views ?? []).filter { !sources.contains(NotionID.compact($0.dataSourceId)) } + views
        try? store.save(catalog: ViewCatalog(views: merged, fetchedAt: cached?.fetchedAt ?? .distantPast))
    }

    /// 캐시된 뷰 중 고른 DB의 것, 고른 순서대로.
    public func cachedCatalog() -> [ViewSummary] {
        let views = store.catalog()?.views ?? []
        return databaseIds().flatMap { id in
            views.filter { NotionID.compact($0.dataSourceId) == NotionID.compact(id) }
        }
    }

    /// 설정이 비었을 때 쓸 뷰: 마지막으로 연 뷰 → 할 일을 보여주는 뷰. 둘 다 고른 DB 안에서.
    public func defaultViewId() async -> String? {
        if let last = store.settings().lastViewId, let view = store.view(last), isChosen(view.dataSourceId) {
            return last
        }
        if let cached = cachedCatalog().preferredDefault { return cached.id }
        return try? await catalog().preferredDefault?.id
    }

    public func rememberLastView(_ id: String) {
        var settings = store.settings()
        settings.lastViewId = id
        try? store.save(settings: settings)
    }

    // MARK: 뷰 정의

    public func resolvedView(_ id: String, refresh: Bool = false) async throws -> ResolvedView {
        if !refresh, let cached = store.view(id), Date.now.timeIntervalSince(cached.resolvedAt) < viewMaxAge {
            return cached
        }
        do {
            let view = try await client.view(id)
            guard let dataSourceId = view.dataSourceId else { throw NotionError.notFound }
            let resolved = ViewResolver.resolve(view: view, schema: try await client.dataSource(dataSourceId))
            try? store.save(view: resolved)
            return resolved
        } catch let error as NotionError where error.isOffline {
            if let cached = store.view(id) { return cached }
            throw error
        }
    }

    // MARK: 조회

    public func cachedItems(_ viewId: String) -> ItemsSnapshot? {
        store.items(viewId).map(applyPending)
    }

    /// data source 쿼리 1회. 대기 중인 쓰기를 먼저 보내고, 남은 대기 항목은 결과 위에 덧씌운다.
    @discardableResult
    public func fetchItems(_ viewId: String) async throws -> ItemsSnapshot {
        await flushPending()
        let view = try await resolvedView(viewId)
        let response = try await client.query(dataSourceId: view.dataSourceId, body: view.queryBody())
        let snapshot = ItemsSnapshot(
            viewId: viewId, items: response.results.filter { $0.inTrash != true }.map(view.item(from:)),
            hasMore: response.hasMore, fetchedAt: .now)
        try? store.save(items: snapshot)
        return applyPending(snapshot)
    }

    func applyPending(_ snapshot: ItemsSnapshot) -> ItemsSnapshot {
        var result = snapshot
        // 만들어질 항목은 뷰 조건을 채운다 → "완료함" 같은 뷰에서는 체크된 채로 생긴다.
        let createsDone = store.view(snapshot.viewId)?.showsDone ?? false
        for op in store.pending() where op.viewId == snapshot.viewId {
            switch op.kind {
            case .setDone(let pageId, let done):
                if let i = result.items.firstIndex(where: { $0.id == pageId }) {
                    result.items[i].isDone = done
                    result.items[i].isPending = true
                }
            case .rename(let pageId, let title):
                if let i = result.items.firstIndex(where: { $0.id == pageId }) {
                    result.items[i].title = title
                    result.items[i].isPending = true
                }
            case .trash(let pageId):
                result.items.removeAll { $0.id == pageId }
            case .create(let localId, let title):
                if !result.items.contains(where: { $0.id == localId }) {
                    result.items.insert(
                        TodoItem(id: localId, title: title, isDone: createsDone, isPending: true), at: 0)
                }
            }
        }
        return result
    }

    // MARK: 쓰기

    /// 완료 상태를 바꾼다. 위젯의 `ToggleTodoIntent`가 잠금 상태에서도 부른다.
    public func setDone(viewId: String, itemId: String, done: Bool) async throws {
        let view = try await resolvedView(viewId)
        guard view.completion.isWritable else { throw TodoError.readOnly }
        if let localCreate = pendingCreate(localId: itemId) {
            // 아직 만들어지지 않은 항목: 만들기 대기를 지우면 체크한 것과 같다.
            if done { removePending(localCreate.id) }
            return
        }
        try enqueue(PendingOperation(viewId: viewId, kind: .setDone(pageId: itemId, done: done)))
        await flushPending()
    }

    @discardableResult
    public func add(viewId: String, title: String) async throws -> TodoItem {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TodoError.emptyTitle }
        let localId = TodoItem.localPrefix + UUID().uuidString
        try enqueue(PendingOperation(viewId: viewId, kind: .create(localId: localId, title: text)))
        await flushPending()
        return TodoItem(id: localId, title: text, isDone: store.view(viewId)?.showsDone ?? false, isPending: true)
    }

    public func rename(viewId: String, itemId: String, title: String) async throws {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TodoError.emptyTitle }
        if var create = pendingCreate(localId: itemId), case .create(let localId, _) = create.kind {
            create.kind = .create(localId: localId, title: text)
            replacePending(create)
            return
        }
        try enqueue(PendingOperation(viewId: viewId, kind: .rename(pageId: itemId, title: text)))
        await flushPending()
    }

    /// Notion 휴지통으로 보낸다 (Notion에서 30일간 복구 가능).
    public func trash(viewId: String, itemId: String) async throws {
        if let create = pendingCreate(localId: itemId) {
            removePending(create.id)
            return
        }
        try enqueue(PendingOperation(viewId: viewId, kind: .trash(pageId: itemId)))
        await flushPending()
    }

    // MARK: 대기열

    func enqueue(_ op: PendingOperation) throws {
        var queue = store.pending()
        // 같은 항목의 같은 종류 변경은 마지막 것만 남긴다 (체크 → 해제 → 체크).
        queue.removeAll { existing in
            existing.pageId == op.pageId && existing.kind.sameKind(as: op.kind) && !existing.kind.isCreate
        }
        queue.append(op)
        try store.save(pending: queue)
    }

    func pendingCreate(localId: String) -> PendingOperation? {
        store.pending().first { if case .create(localId, _) = $0.kind { true } else { false } }
    }

    func removePending(_ id: UUID) {
        var queue = store.pending()
        queue.removeAll { $0.id == id }
        try? store.save(pending: queue)
    }

    func replacePending(_ op: PendingOperation) {
        var queue = store.pending()
        if let i = queue.firstIndex(where: { $0.id == op.id }) { queue[i] = op }
        try? store.save(pending: queue)
    }

    public var pendingCount: Int { store.pending().count }

    /// 대기 중인 쓰기를 순서대로 보낸다. 네트워크 오류면 멈추고 다음 기회에 다시 보낸다.
    /// 되돌릴 수 없는 오류(항목 삭제됨·권한 없음)는 버린다.
    public func flushPending() async {
        // actor 재진입으로 같은 대기 항목을 두 번 보내지 않게 한다.
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        for op in store.pending() {
            do {
                try await send(op)
                removePending(op.id)
            } catch let error as NotionError where error.isOffline || error == .rateLimited || error == .unauthorized {
                return
            } catch {
                var failed = op
                failed.attempts += 1
                if failed.attempts >= 3 { removePending(op.id) } else { replacePending(failed) }
            }
        }
    }

    func send(_ op: PendingOperation) async throws {
        let view = try await resolvedView(op.viewId)
        switch op.kind {
        case .setDone(let pageId, let done):
            guard let patch = view.completionPatch(done: done) else { throw TodoError.readOnly }
            _ = try await client.updatePage(pageId, properties: patch)
            updateCachedItem(viewId: op.viewId, pageId: pageId) { $0.isDone = done }
        case .create(let localId, let title):
            let owner = await auth.credentials?.ownerUserId
            let page = try await client.createPage(
                dataSourceId: view.dataSourceId, properties: view.createProperties(title: title, ownerUserId: owner))
            replaceCachedItem(viewId: op.viewId, localId: localId, with: view.item(from: page))
        case .rename(let pageId, let title):
            _ = try await client.updatePage(pageId, properties: view.titlePatch(title))
            updateCachedItem(viewId: op.viewId, pageId: pageId) { $0.title = title }
        case .trash(let pageId):
            _ = try await client.updatePage(pageId, inTrash: true)
            if var snapshot = store.items(op.viewId) {
                snapshot.items.removeAll { $0.id == pageId }
                try? store.save(items: snapshot)
            }
        }
    }

    func updateCachedItem(viewId: String, pageId: String, _ change: (inout TodoItem) -> Void) {
        guard var snapshot = store.items(viewId), let i = snapshot.items.firstIndex(where: { $0.id == pageId }) else {
            return
        }
        change(&snapshot.items[i])
        try? store.save(items: snapshot)
    }

    func replaceCachedItem(viewId: String, localId: String, with item: TodoItem) {
        var snapshot = store.items(viewId) ?? ItemsSnapshot(viewId: viewId, items: [], hasMore: false, fetchedAt: .now)
        snapshot.items.removeAll { $0.id == localId || $0.id == item.id }
        snapshot.items.insert(item, at: 0)
        try? store.save(items: snapshot)
    }

    // MARK: 계정

    public func signOut() async {
        await auth.signOut()
        store.wipe()
    }
}

public enum TodoError: Error, Equatable, Sendable {
    case readOnly
    case emptyTitle
    case noView
    /// 새 DB를 둘 곳이 없다: 워크스페이스 맨 위에 만들 수 없는 연결인데 공유된 페이지도 없다.
    case nowhereToCreate
}

extension PendingOperation.Kind {
    var isCreate: Bool {
        if case .create = self { return true }
        return false
    }

    func sameKind(as other: Self) -> Bool {
        switch (self, other) {
        case (.setDone, .setDone), (.rename, .rename), (.trash, .trash), (.create, .create): true
        default: false
        }
    }
}
