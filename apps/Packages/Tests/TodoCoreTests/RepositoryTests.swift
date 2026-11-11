import Foundation
import NotionKit
import Testing

@testable import TodoCore

/// URLSession 요청을 가로채 Notion을 흉내 낸다.
final class MockNotion: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data?) -> (Int, JSONValue))?
    nonisolated(unsafe) static var requests: [(method: String, path: String, body: JSONValue?, query: [URLQueryItem])] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let decoded = body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        Self.lock.withLock {
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            Self.requests.append((request.httpMethod ?? "", request.url?.path ?? "", decoded, query))
        }
        guard let handler = Self.lock.withLock({ Self.handler }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (status, json) = handler(request, body)
        if status == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONEncoder().encode(json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    static func reset(_ handler: (@Sendable (URLRequest, Data?) -> (Int, JSONValue))?) {
        lock.withLock {
            self.handler = handler
            requests = []
        }
    }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockNotion.self]
        return URLSession(configuration: config)
    }
}

@Suite(.serialized) struct RepositoryTests {
    let store: SharedStore
    let repository: TodoRepository
    let view: ResolvedView

    init() throws {
        store = SharedStore(root: FileManager.default.temporaryDirectory.appending(path: "nt-tests-\(UUID().uuidString)"))
        let auth = AuthSession(
            store: InMemoryCredentialStore(Credentials(kind: .oauth, accessToken: "t", ownerUserId: "owner")),
            config: nil, session: MockNotion.session)
        repository = TodoRepository(
            client: NotionClient(tokens: auth, session: MockNotion.session, maxRetries: 0), store: store, auth: auth)
        view = ViewResolver.resolve(view: try Fixture.load("view-memo-todo"), schema: try Fixture.memoSchema)
        try store.save(view: view)
        try store.save(
            items: ItemsSnapshot(
                viewId: view.id, items: [TodoItem(id: "p1", title: "치약 사기", isDone: false)], hasMore: false,
                fetchedAt: .now))
    }

    @Test func offlineToggleStaysPendingThenFlushes() async throws {
        MockNotion.reset(nil)  // 오프라인
        try await repository.setDone(viewId: view.id, itemId: "p1", done: true)
        #expect(store.pending().count == 1)
        let cached = try #require(await repository.cachedItems(view.id))
        #expect(cached.items.first?.isDone == true)
        #expect(cached.items.first?.isPending == true)

        MockNotion.reset { _, _ in (200, ["object": "page", "id": "p1", "properties": [:]]) }
        await repository.flushPending()
        #expect(store.pending().isEmpty)
        let patch = try #require(MockNotion.requests.first { $0.method == "PATCH" })
        #expect(patch.path.hasSuffix("/pages/p1"))
        #expect(patch.body == ["properties": ["%3BQFf": ["checkbox": true]]])
        #expect(store.items(view.id)?.items.first?.isDone == true)
    }

    @Test func repeatedTogglesCollapse() async throws {
        MockNotion.reset(nil)
        try await repository.setDone(viewId: view.id, itemId: "p1", done: true)
        try await repository.setDone(viewId: view.id, itemId: "p1", done: false)
        let queue = store.pending()
        #expect(queue.count == 1)
        #expect(queue.first?.kind == .setDone(pageId: "p1", done: false))
    }

    @Test func addCreatesPageWithViewDefaults() async throws {
        MockNotion.reset { request, _ in
            let page: JSONValue = [
                "object": "page", "id": "new-page", "created_time": "2026-11-09T03:00:00.000Z",
                "properties": [
                    "내용": ["id": "title", "type": "title", "title": [["plain_text": "우유"]]],
                    "완료": ["id": "%3BQFf", "type": "checkbox", "checkbox": false],
                ],
            ]
            return (200, page)
        }
        let local = try await repository.add(viewId: view.id, title: "  우유 ")
        #expect(local.isLocalOnly)
        let post = try #require(MockNotion.requests.first { $0.method == "POST" && $0.path.hasSuffix("/pages") })
        #expect(post.body?["parent"] == ["type": "data_source_id", "data_source_id": .string(view.dataSourceId)])
        #expect(post.body?["properties"]?["%3BQFf"] == ["checkbox": false])
        #expect(post.body?["properties"]?["title"] == ["title": [["text": ["content": "우유"]]]])
        let items = try #require(store.items(view.id)).items
        #expect(items.first?.id == "new-page")
        #expect(!items.contains { $0.isLocalOnly })
        #expect(store.pending().isEmpty)
    }

    @Test func offlineAddThenCheckCancelsCreate() async throws {
        MockNotion.reset(nil)
        let local = try await repository.add(viewId: view.id, title: "우유")
        #expect(await repository.cachedItems(view.id)?.items.first?.id == local.id)
        try await repository.setDone(viewId: view.id, itemId: local.id, done: true)
        #expect(store.pending().isEmpty)
    }

    /// "완료함"처럼 체크된 항목을 보여주는 뷰에 오프라인으로 추가하면, 대기 항목도 체크된 채로 보여야 뷰에 남는다.
    @Test func offlineAddInDoneViewShowsChecked() async throws {
        MockNotion.reset(nil)
        let done = ViewResolver.resolve(view: try Fixture.load("view-memo-done"), schema: try Fixture.memoSchema)
        try store.save(view: done)
        try store.save(items: ItemsSnapshot(viewId: done.id, items: [], hasMore: false, fetchedAt: .now))
        let local = try await repository.add(viewId: done.id, title: "다 한 일")
        let item = try #require(await repository.cachedItems(done.id)?.items.first { $0.id == local.id })
        #expect(item.isDone)
        #expect(item.isPending)
    }

    @Test func fetchReplacesCacheAndKeepsPendingOverlay() async throws {
        MockNotion.reset(nil)
        try await repository.trash(viewId: view.id, itemId: "p1")
        let pages = try Fixture.data("query-memo")
        let json = try JSONDecoder().decode(JSONValue.self, from: pages)
        MockNotion.reset { request, _ in
            // trash PATCH는 실패시켜 대기열에 남긴다(404 아닌 500 → 재시도 대상).
            request.httpMethod == "PATCH" ? (0, nil) : (200, json)
        }
        let snapshot = try await repository.fetchItems(view.id)
        #expect(Set(snapshot.items.map(\.title)) == ["치약 사기", "택배 반품 접수"])
        #expect(store.pending().count == 1)
    }

    /// 쿼리는 항목을 만드는 데 읽는 속성만 받는다 (응답이 작아진다).
    @Test func fetchAsksOnlyForPropertiesItReads() async throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("query-memo"))
        MockNotion.reset { _, _ in (200, json) }
        try await repository.fetchItems(view.id)
        let query = try #require(MockNotion.requests.first { $0.path.hasSuffix("/query") })
        #expect(query.query.allSatisfy { $0.name == "filter_properties" })
        #expect(query.query.map(\.value) == ["title", "%3BQFf"])
    }

    /// 캐시한 뷰가 가리키는 속성이 Notion에서 지워졌으면 400이 온다. 뷰를 다시 읽고 한 번 더 묻는다.
    @Test func staleViewIsResolvedAgainWhenQueryIsRejected() async throws {
        var stale = view
        stale.datePropertyId = "gone"
        stale.resolvedAt = .now.addingTimeInterval(-600)
        try store.save(view: stale)
        let todo = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("view-memo-todo"))
        let schema = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("data-source-memo"))
        let pages = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("query-memo"))
        let viewId = view.id
        let memoId = view.dataSourceId
        MockNotion.reset { request, _ in
            let url = request.url?.absoluteString ?? ""
            switch request.url?.path ?? "" {
            case "/v1/views/\(viewId)": return (200, todo)
            case "/v1/data_sources/\(memoId)": return (200, schema)
            default:
                return url.contains("filter_properties=gone")
                    ? (400, ["code": "validation_error", "message": "invalid attribute: gone"]) : (200, pages)
            }
        }
        let snapshot = try await repository.fetchItems(view.id)
        #expect(snapshot.items.count == 2)
        #expect(store.view(view.id)?.datePropertyId == view.datePropertyId)
        #expect(MockNotion.requests.filter { $0.path.hasSuffix("/query") }.count == 2)
    }

    /// 방금 읽은 뷰 정의로도 거절되면 다시 읽지 않고 오류를 그대로 올린다.
    @Test func freshViewIsNotResolvedAgain() async throws {
        MockNotion.reset { _, _ in (400, ["code": "validation_error", "message": "bad filter"]) }
        await #expect(throws: NotionError.http(status: 400, code: "validation_error", message: "bad filter")) {
            try await repository.fetchItems(view.id)
        }
        #expect(MockNotion.requests.count == 1)
    }

    @Test func readOnlyViewRejectsToggle() async throws {
        var readOnly = view
        readOnly.id = "ro"
        readOnly.completion = .readOnly(.ambiguous)
        try store.save(view: readOnly)
        await #expect(throws: TodoError.readOnly) {
            try await repository.setDone(viewId: "ro", itemId: "p1", done: true)
        }
    }

    @Test func unauthorizedWithoutRefreshSignalsSignIn() async throws {
        MockNotion.reset { _, _ in (401, ["code": "unauthorized"]) }
        await #expect(throws: NotionError.unauthorized) {
            try await repository.fetchItems(view.id)
        }
    }

    // MARK: 고른 DB

    /// 고른 DB만 받는다 (검색하지 않는다). 휴지통에 있거나 연결에서 빠진 DB는 고른 목록에서도 뺀다.
    @Test func catalogHasOnlyChosenDatabases() async throws {
        let todo = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("view-memo-todo"))
        let done = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("view-memo-done"))
        let schema = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("data-source-memo"))
        let todoId = try #require(todo["id"]?.stringValue)
        let doneId = try #require(done["id"]?.stringValue)
        let memoId = view.dataSourceId
        try store.save(settings: AppSettings(databaseIds: ["gone-ds", memoId]))
        MockNotion.reset { request, _ in
            switch request.url?.path ?? "" {
            case "/v1/data_sources/\(memoId)": return (200, schema)
            case "/v1/views":
                let ids: JSONValue = [["object": "view", "id": .string(doneId)], ["object": "view", "id": .string(todoId)]]
                return (200, ["object": "list", "results": ids, "has_more": false])
            case "/v1/views/\(todoId)": return (200, todo)
            case "/v1/views/\(doneId)": return (200, done)
            default: return (404, ["object": "error", "code": "object_not_found"])
            }
        }
        let catalog = try await repository.catalog(refresh: true)
        #expect(catalog.map(\.name) == ["완료함", "할 일"])
        #expect(!MockNotion.requests.contains { $0.path.hasSuffix("/search") })
        #expect(store.settings().databaseIds == [memoId])
    }

    /// 고른 DB를 기록하기 전 버전에서 올라오면 마지막으로 연 뷰의 DB만 남는다.
    @Test func upgradeKeepsLastViewDatabaseOnly() async throws {
        var other = view.summary
        other.id = "v-other"
        other.dataSourceId = "other-ds"
        try store.save(catalog: ViewCatalog(views: [other, view.summary], fetchedAt: .now))
        try store.save(settings: AppSettings(lastViewId: view.id))
        #expect(await repository.cachedCatalog() == [view.summary])
        #expect(store.settings().databaseIds == [view.dataSourceId])
        #expect(store.settings().lastViewId == view.id)
    }

    /// 뺀 DB의 뷰는 목록에서 사라지고, 마지막으로 연 뷰였어도 기본값이 되지 않는다.
    @Test func removedDatabaseLeavesCatalogAndDefault() async throws {
        var other = view
        other.id = "v-other"
        other.dataSourceId = "other-ds"
        try store.save(view: other)
        try store.save(catalog: ViewCatalog(views: [view.summary, other.summary], fetchedAt: .now))
        try store.save(settings: AppSettings(lastViewId: other.id, databaseIds: [view.dataSourceId, "other-ds"]))
        #expect(await repository.defaultViewId() == other.id)

        await repository.removeDatabase("other-ds")
        #expect(await repository.cachedCatalog() == [view.summary])
        #expect(await repository.defaultViewId() == view.id)
    }

    // MARK: 배치 (순서·섹션)

    /// 오프라인으로 만든 항목을 섹션에 넣어 두면, Notion에 올라가 ID가 바뀌어도 그 자리에 남는다.
    @Test func layoutFollowsItemWhenOfflineCreateSyncs() async throws {
        MockNotion.reset(nil)
        let local = try await repository.add(viewId: view.id, title: "우유")
        let section = LayoutSection(title: "장보기", tint: .green)
        let visible = try #require(await repository.cachedItems(view.id)).items.map(\.id)
        await repository.updateLayout(view.id) {
            $0.sections.append(section)
            $0.move(itemId: local.id, toSection: section.id, visibleIds: visible)
        }
        #expect(store.layout(view.id)?.sections.first?.itemIds == [local.id])

        MockNotion.reset { _, _ in (200, ["object": "page", "id": "new-page", "properties": [:]]) }
        await repository.flushPending()
        let layout = try #require(store.layout(view.id))
        #expect(layout.sections.first?.itemIds == ["new-page"])
        #expect(layout.itemIds == ["p1"])
        let ordered = await repository.orderedItems(try #require(await repository.cachedItems(view.id)))
        #expect(ordered.map(\.id) == ["p1", "new-page"], "위젯·메뉴 막대도 같은 순서: 섹션 밖 → 섹션")
    }

    /// 배치가 비면 파일도 지운다. 변경이 없으면 쓰지 않는다.
    @Test func emptyLayoutLeavesNoFile() async throws {
        let section = LayoutSection(title: "오늘", tint: .yellow)
        let added = await repository.updateLayout(view.id) { $0.sections.append(section) }
        #expect(added.sections.map(\.title) == ["오늘"])
        #expect(FileManager.default.fileExists(atPath: store.layoutURL(view.id).path))
        let removed = await repository.updateLayout(view.id) { $0.removeSection(section.id) }
        #expect(removed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.layoutURL(view.id).path))
        #expect(await repository.layout(view.id) == ViewLayout())
    }

    /// 조회할 때 뷰에서 사라진 항목을 배치에서 치우되, 50개까지는 남겨 둔다.
    @Test func fetchPrunesLayoutOnlyWhenManyItemsAreGone() async throws {
        let pages = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("query-memo"))
        MockNotion.reset { _, _ in (200, pages) }
        let fetched = try await repository.fetchItems(view.id).items.map(\.id)
        let few = (1...5).map { "gone-\($0)" }
        await repository.updateLayout(view.id) { $0.itemIds = fetched + few }
        try await repository.fetchItems(view.id)
        #expect(store.layout(view.id)?.itemIds == fetched + few)

        let many = (1...60).map { "gone-\($0)" }
        await repository.updateLayout(view.id) { $0.itemIds = fetched + many }
        try await repository.fetchItems(view.id)
        #expect(store.layout(view.id)?.itemIds == fetched)
    }

    // MARK: 로그인·시작 DB (MockNotion을 같이 쓰므로 이 직렬 묶음 안에 둔다)

    static let oauth = OAuthConfig(clientId: "cid", authBaseURL: URL(string: "https://auth.example.com")!)

    @Test func signInExchangesCodeThroughFunction() async throws {
        MockNotion.reset { _, _ in
            let owner: JSONValue = ["type": "user", "user": ["object": "user", "id": "u1", "name": "현우"]]
            return (200, ["access_token": "at", "refresh_token": "rt", "bot_id": "b", "workspace_name": "내 공간", "owner": owner])
        }
        let store = InMemoryCredentialStore()
        let auth = AuthSession(store: store, config: Self.oauth, session: MockNotion.session)
        let pkce = PKCE()
        var callback = URLComponents(string: "notiontodo://oauth")!
        callback.queryItems = [URLQueryItem(name: "code", value: "c"), URLQueryItem(name: "state", value: pkce.state)]

        let credentials = try await auth.completeSignIn(callback: try #require(callback.url), pkce: pkce)
        #expect(credentials.kind == .oauth)
        #expect(credentials.workspaceName == "내 공간")
        #expect(credentials.ownerName == "현우")
        #expect(store.load()?.refreshToken == "rt")
        let post = try #require(MockNotion.requests.first)
        #expect(post.method == "POST" && post.path == "/token")
        #expect(post.body == ["code": "c", "state": .string(pkce.state), "code_verifier": .string(pkce.verifier)])
    }

    @Test func deniedOrForgedCallbackDoesNotSignIn() async throws {
        MockNotion.reset { _, _ in (200, ["access_token": "at"]) }
        let auth = AuthSession(store: InMemoryCredentialStore(), config: Self.oauth, session: MockNotion.session)
        let pkce = PKCE()
        // Notion 화면에서 "취소"를 누르면 error=access_denied로 돌아온다 → 창을 닫은 것과 같다.
        await #expect(throws: AuthError.canceled) {
            try await auth.completeSignIn(
                callback: URL(string: "notiontodo://oauth?error=access_denied&state=\(pkce.state)")!, pkce: pkce)
        }
        await #expect(throws: AuthError.stateMismatch) {
            try await auth.completeSignIn(callback: URL(string: "notiontodo://oauth?code=c&state=forged")!, pkce: pkce)
        }
        #expect(MockNotion.requests.isEmpty)
        #expect(await auth.credentials == nil)
    }

    @Test func databaseChoicesPutStarterFirst() async throws {
        let search = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("search-data-sources"))
        let reversed = Array((search["results"]?.arrayValue ?? []).reversed())
        MockNotion.reset { _, _ in (200, ["object": "list", "results": .array(reversed), "has_more": false]) }
        let choices = try await repository.databaseChoices()
        #expect(choices.map(\.title) == ["할 일 메모", "probe-views 테스트"])
        // 최근에 고친 것부터, 상한까지만 받는다 (개인 액세스 토큰은 워크스페이스 전체를 본다).
        let request = try #require(MockNotion.requests.first { $0.path.hasSuffix("/search") })
        #expect(request.body?["sort"] == ["direction": "descending", "timestamp": "last_edited_time"])
        #expect(request.body?["page_size"] == 30)

        // "DB 추가"에서는 이미 고른 DB를 뺀다 (대시 없이 저장된 ID도 같은 DB).
        try store.save(settings: AppSettings(databaseIds: [NotionID.compact(view.dataSourceId)]))
        #expect(try await repository.databaseChoices(excludingChosen: true).map(\.title) == ["probe-views 테스트"])
    }

    /// 새 메모 DB 만들기에 필요한 응답들. `databases`는 만들기 요청 본문을 보고 상태 코드를 정한다.
    func starterHandler(databases: @escaping @Sendable (JSONValue?) -> Int) throws
        -> @Sendable (URLRequest, Data?) -> (Int, JSONValue)
    {
        let todo = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("view-memo-todo"))
        let done = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("view-memo-done"))
        let schema = try JSONDecoder().decode(JSONValue.self, from: Fixture.data("data-source-memo"))
        let todoId = try #require(todo["id"]?.stringValue)
        let doneId = try #require(done["id"]?.stringValue)
        let pages: JSONValue = [
            "object": "list", "has_more": false,
            "results": [
                ["object": "page", "id": "p-child", "parent": ["type": "page_id", "page_id": "p-root"], "properties": [:]],
                ["object": "page", "id": "p-root", "parent": ["type": "workspace", "workspace": true], "properties": [:]],
            ],
        ]
        return { request, body in
            let path = request.url?.path ?? ""
            switch (request.httpMethod ?? "", path) {
            case ("POST", "/v1/databases"):
                let status = databases(body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) })
                guard status == 200 else { return (status, ["object": "error", "code": "validation_error"]) }
                return (200, ["object": "database", "id": "db1", "title": [], "data_sources": [["id": "ds1"]]])
            case ("POST", "/v1/search"): return (200, pages)
            case ("GET", "/v1/views"):
                return (200, ["object": "list", "results": [["object": "view", "id": "v-default"]], "has_more": false])
            case ("PATCH", "/v1/views/v-default"), ("GET", "/v1/views/\(todoId)"): return (200, todo)
            case ("POST", "/v1/views"), ("GET", "/v1/views/\(doneId)"): return (200, done)
            case ("GET", _) where path.hasPrefix("/v1/data_sources/"): return (200, schema)
            default: return (404, ["object": "error", "code": "object_not_found"])
            }
        }
    }

    @Test func starterDatabaseGoesToWorkspaceTopLevel() async throws {
        MockNotion.reset(try starterHandler { _ in 200 })
        let summary = try await repository.createStarterDatabase(template: .korean)
        #expect(summary.name == "할 일")
        #expect(!summary.showsDone)
        let create = try #require(MockNotion.requests.first { $0.path == "/v1/databases" })
        #expect(create.body?["parent"] == ["type": "workspace", "workspace": true])
        #expect(create.body?["title"] == [["text": ["content": "할 일 메모"]]])
        // 전체 목록을 다시 받기 전에도 두 뷰가 목록에 있다.
        #expect(store.catalog()?.views.map(\.name).sorted() == ["완료함", "할 일"])
        #expect(store.settings().lastViewId == summary.id)
        #expect(store.settings().databaseIds == [summary.dataSourceId])
    }

    @Test func starterDatabaseFallsBackToTopSharedPage() async throws {
        // internal integration처럼 맨 위에 만들 수 없으면 공유된 페이지 중 맨 위 페이지 아래에 만든다.
        MockNotion.reset(try starterHandler { body in body?["parent"]?["type"] == "workspace" ? 400 : 200 })
        let summary = try await repository.createStarterDatabase(template: .korean)
        #expect(summary.name == "할 일")
        let creates = MockNotion.requests.filter { $0.path == "/v1/databases" }
        #expect(creates.map { $0.body?["parent"]?["type"] } == ["workspace", "page_id"])
        #expect(creates.last?.body?["parent"]?["page_id"] == "p-root")
    }

}
