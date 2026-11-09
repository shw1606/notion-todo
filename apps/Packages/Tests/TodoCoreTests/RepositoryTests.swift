import Foundation
import NotionKit
import Testing

@testable import TodoCore

/// URLSession 요청을 가로채 Notion을 흉내 낸다.
final class MockNotion: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data?) -> (Int, JSONValue))?
    nonisolated(unsafe) static var requests: [(method: String, path: String, body: JSONValue?)] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let decoded = body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        Self.lock.withLock {
            Self.requests.append((request.httpMethod ?? "", request.url?.path ?? "", decoded))
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
}
