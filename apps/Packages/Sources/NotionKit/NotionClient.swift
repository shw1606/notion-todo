import Foundation

public enum NotionError: Error, Equatable, Sendable {
    /// 토큰이 없거나 만료·취소됨. 다시 로그인해야 한다.
    case unauthorized
    case notFound
    case rateLimited
    case http(status: Int, code: String?, message: String?)
    case network(String)
    case decoding(String)

    public var isOffline: Bool {
        if case .network = self { return true }
        return false
    }
}

/// 토큰을 꺼내고, 401을 받았을 때 한 번 갱신을 시도하는 쪽. 앱에서는 TodoCore의 `AuthSession`이 맡는다.
public protocol NotionTokenProvider: Sendable {
    func accessToken() async throws -> String
    /// 갱신에 성공하면 새 토큰, 갱신할 수 없으면 nil.
    func refreshAfterUnauthorized(failedToken: String) async throws -> String?
}

public struct StaticTokenProvider: NotionTokenProvider {
    let token: String
    public init(_ token: String) { self.token = token }
    public func accessToken() async throws -> String { token }
    public func refreshAfterUnauthorized(failedToken: String) async throws -> String? { nil }
}

public final class NotionClient: Sendable {
    public static let apiVersion = "2026-03-11"

    let baseURL: URL
    let session: URLSession
    let tokens: any NotionTokenProvider
    let maxRetries: Int

    public init(
        tokens: any NotionTokenProvider,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.notion.com/v1")!,
        maxRetries: Int = 3
    ) {
        self.tokens = tokens
        self.session = session
        self.baseURL = baseURL
        self.maxRetries = maxRetries
    }

    // MARK: 요청

    public func send<Response: Decodable>(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil,
        as: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await sendRaw(method, path, query: query, body: body)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw NotionError.decoding("\(method) \(path): \(error)")
        }
    }

    func sendRaw(_ method: String, _ path: String, query: [URLQueryItem], body: JSONValue?) async throws -> Data {
        var token = try await tokens.accessToken()
        var refreshed = false
        var attempt = 0
        while true {
            let request = try makeRequest(method, path, query: query, body: body, token: token)
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError {
                if attempt < maxRetries, error.code == .timedOut || error.code == .networkConnectionLost {
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(300 * attempt))
                    continue
                }
                throw NotionError.network(error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                return data
            case 401:
                if !refreshed, let next = try await tokens.refreshAfterUnauthorized(failedToken: token) {
                    token = next
                    refreshed = true
                    continue
                }
                throw NotionError.unauthorized
            case 429, 500, 502, 503, 504:
                guard attempt < maxRetries else {
                    throw status == 429 ? NotionError.rateLimited : Self.httpError(status, data)
                }
                attempt += 1
                let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init) ?? pow(2, Double(attempt - 1)) * 0.5
                try await Task.sleep(for: .seconds(min(retryAfter, 10)))
            case 404:
                throw NotionError.notFound
            default:
                throw Self.httpError(status, data)
            }
        }
    }

    func makeRequest(_ method: String, _ path: String, query: [URLQueryItem], body: JSONValue?, token: String)
        throws -> URLRequest
    {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    static func httpError(_ status: Int, _ data: Data) -> NotionError {
        let body = try? JSONDecoder().decode(JSONValue.self, from: data)
        return .http(status: status, code: body?["code"]?.stringValue, message: body?["message"]?.stringValue)
    }
}

// MARK: - 엔드포인트

extension NotionClient {
    public func me() async throws -> NotionUser {
        try await send("GET", "users/me")
    }

    /// 연결에 공유된 data source 전체.
    public func searchDataSources() async throws -> [DataSource] {
        try await paginate { cursor in
            var body: [String: JSONValue] = ["filter": ["property": "object", "value": "data_source"], "page_size": 100]
            if let cursor { body["start_cursor"] = .string(cursor) }
            return try await self.send("POST", "search", body: .object(body), as: ListResponse<DataSource>.self)
        }
    }

    /// 연결에 공유된 페이지 (온보딩에서 새 DB를 만들 부모 페이지 고르기).
    public func searchPages(query: String? = nil) async throws -> [Page] {
        var body: [String: JSONValue] = ["filter": ["property": "object", "value": "page"], "page_size": 50]
        if let query, !query.isEmpty { body["query"] = .string(query) }
        let response = try await send("POST", "search", body: .object(body), as: ListResponse<Page>.self)
        return response.results
    }

    public func database(_ id: String) async throws -> Database {
        try await send("GET", "databases/\(id)")
    }

    public func dataSource(_ id: String) async throws -> DataSource {
        try await send("GET", "data_sources/\(id)")
    }

    public func viewIds(dataSourceId: String) async throws -> [String] {
        let refs = try await paginate { cursor in
            var query = [URLQueryItem(name: "data_source_id", value: dataSourceId)]
            if let cursor { query.append(URLQueryItem(name: "start_cursor", value: cursor)) }
            return try await self.send("GET", "views", query: query, as: ListResponse<ObjectRef>.self)
        }
        return refs.map(\.id)
    }

    public func view(_ id: String) async throws -> NotionView {
        try await send("GET", "views/\(id)")
    }

    /// `body`는 filter·sorts·page_size를 담은 쿼리 본문.
    public func query(dataSourceId: String, body: JSONValue) async throws -> ListResponse<Page> {
        try await send("POST", "data_sources/\(dataSourceId)/query", body: body)
    }

    public func createPage(dataSourceId: String, properties: JSONValue) async throws -> Page {
        try await send(
            "POST", "pages",
            body: ["parent": ["type": "data_source_id", "data_source_id": .string(dataSourceId)], "properties": properties])
    }

    public func updatePage(_ id: String, properties: JSONValue? = nil, inTrash: Bool? = nil) async throws -> Page {
        var body: [String: JSONValue] = [:]
        if let properties { body["properties"] = properties }
        if let inTrash { body["in_trash"] = .bool(inTrash) }
        return try await send("PATCH", "pages/\(id)", body: .object(body))
    }

    public func createDatabase(parentPageId: String, title: String, emoji: String?, properties: JSONValue)
        async throws -> Database
    {
        var body: [String: JSONValue] = [
            "parent": ["type": "page_id", "page_id": .string(parentPageId)],
            "title": [["text": ["content": .string(title)]]],
            "initial_data_source": ["properties": properties],
        ]
        if let emoji { body["icon"] = ["type": "emoji", "emoji": .string(emoji)] }
        return try await send("POST", "databases", body: .object(body))
    }

    public func createView(databaseId: String, dataSourceId: String, name: String, body extra: [String: JSONValue])
        async throws -> NotionView
    {
        var body = extra
        body["database_id"] = .string(databaseId)
        body["data_source_id"] = .string(dataSourceId)
        body["name"] = .string(name)
        body["type"] = body["type"] ?? "table"
        return try await send("POST", "views", body: .object(body))
    }

    public func updateView(_ id: String, body: [String: JSONValue]) async throws -> NotionView {
        try await send("PATCH", "views/\(id)", body: .object(body))
    }

    func paginate<Item>(_ fetch: (String?) async throws -> ListResponse<Item>) async throws -> [Item] {
        var items: [Item] = []
        var cursor: String?
        repeat {
            let page = try await fetch(cursor)
            items += page.results
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil && items.count < 1000
        return items
    }
}
