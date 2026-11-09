import Foundation
import Testing

@testable import NotionKit

@Suite struct JSONValueTests {
    @Test func roundTripKeepsIntegers() throws {
        let value: JSONValue = ["page_size": 100, "ratio": .number(0.5), "ok": true, "none": nil, "list": ["a"]]
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        #expect(text.contains("\"page_size\":100"))
        #expect(!text.contains("100.0"))
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == value)
    }

    @Test func boolIsNotNumber() throws {
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8)) == .bool(true))
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data("1".utf8)) == .number(1))
    }
}

@Suite struct NotionIDTests {
    @Test func propertyIdsCompareDecoded() {
        #expect(NotionID.property("%3BQFf") == ";QFf")
        #expect(NotionID.property("~%3Ax%7C") == "~:x|")
        #expect(NotionID.property("title") == "title")
    }

    @Test func extractsIdFromURL() {
        #expect(
            NotionID.extract(from: "https://app.notion.com/p/notion-todo-413e485b4fdb803ab3f1efeb5a93f94a")
                == "413e485b4fdb803ab3f1efeb5a93f94a")
        #expect(NotionID.extract(from: "b41d0c41-906d-40ce-93a9-7e93b4a9bcce") == "b41d0c41906d40ce93a97e93b4a9bcce")
        #expect(NotionID.extract(from: "nothing") == nil)
    }
}

/// 상태 코드 순서대로 응답하는 목.
final class SequenceProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statuses: [Int] = []
    nonisolated(unsafe) static var authHeaders: [String] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.lock.withLock {
            Self.authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"object":"user","id":"u","code":"x"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session(_ statuses: [Int]) -> URLSession {
        lock.withLock {
            self.statuses = statuses
            authHeaders = []
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SequenceProtocol.self]
        return URLSession(configuration: config)
    }
}

struct RotatingTokens: NotionTokenProvider {
    func accessToken() async throws -> String { "old" }
    func refreshAfterUnauthorized(failedToken: String) async throws -> String? { "new" }
}

@Suite(.serialized) struct NotionClientTests {
    @Test func retriesRateLimitThenSucceeds() async throws {
        let client = NotionClient(tokens: StaticTokenProvider("t"), session: SequenceProtocol.session([429, 200]))
        let me = try await client.me()
        #expect(me.id == "u")
        #expect(SequenceProtocol.authHeaders.count == 2)
    }

    @Test func gives429AfterRetries() async throws {
        let client = NotionClient(
            tokens: StaticTokenProvider("t"), session: SequenceProtocol.session([429, 429]), maxRetries: 1)
        await #expect(throws: NotionError.rateLimited) { try await client.me() }
    }

    @Test func refreshesOnceOn401() async throws {
        let client = NotionClient(tokens: RotatingTokens(), session: SequenceProtocol.session([401, 200]))
        _ = try await client.me()
        #expect(SequenceProtocol.authHeaders == ["Bearer old", "Bearer new"])
    }

    @Test func secondUnauthorizedIsFinal() async throws {
        let client = NotionClient(tokens: RotatingTokens(), session: SequenceProtocol.session([401, 401]))
        await #expect(throws: NotionError.unauthorized) { try await client.me() }
    }

    @Test func sendsVersionHeader() throws {
        let client = NotionClient(tokens: StaticTokenProvider("t"))
        let request = try client.makeRequest("POST", "search", query: [], body: ["a": 1], token: "t")
        #expect(request.value(forHTTPHeaderField: "Notion-Version") == "2026-03-11")
        #expect(request.url?.absoluteString == "https://api.notion.com/v1/search")
    }
}
