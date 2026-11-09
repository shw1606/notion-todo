import CryptoKit
import Foundation
import NotionKit

/// Notion OAuth 설정. client secret은 앱에 없다 — `auth/` 토큰 교환 함수만 가진다.
public struct OAuthConfig: Sendable, Hashable {
    public var clientId: String
    /// 토큰 교환 함수 주소 (예: `https://auth.example.workers.dev`).
    public var authBaseURL: URL

    public init(clientId: String, authBaseURL: URL) {
        self.clientId = clientId
        self.authBaseURL = authBaseURL
    }

    /// Notion에 등록한 리다이렉트 URI. 앱의 `ASWebAuthenticationSession`이 이 주소로의 이동을 가로챈다.
    public var redirectURI: URL { authBaseURL.appending(path: "callback") }
    public var callbackHost: String { authBaseURL.host() ?? "" }
    public var callbackPath: String { redirectURI.path() }

    public func authorizeURL(pkce: PKCE) -> URL {
        var components = URLComponents(string: "https://api.notion.com/v1/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "owner", value: "user"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return components.url!
    }
}

/// Notion OAuth엔 PKCE가 없어서, 앱↔토큰 교환 함수 사이에서 직접 한다.
/// `state = nonce.challenge`로 보내고, 교환할 때 verifier를 같이 보내면 함수가 대조한다.
/// 리다이렉트를 가로챈 쪽은 code와 state만 알고 verifier는 모르므로 교환할 수 없다.
public struct PKCE: Sendable, Hashable {
    public var verifier: String
    public var nonce: String

    public init(verifier: String = PKCE.randomToken(), nonce: String = PKCE.randomToken(byteCount: 16)) {
        self.verifier = verifier
        self.nonce = nonce
    }

    public var challenge: String { Self.challenge(for: verifier) }
    public var state: String { "\(nonce).\(challenge)" }

    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    public static func randomToken(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum AuthError: Error, Equatable, Sendable {
    case signedOut
    case stateMismatch
    case missingCode
    case exchangeFailed(String)
}

/// 토큰을 꺼내 주고 401이면 갱신한다. 앱과 위젯이 같은 Keychain 항목을 쓰므로 프로세스 간 경쟁을 고려한다.
public actor AuthSession: NotionTokenProvider {
    let store: any CredentialStore
    let config: OAuthConfig?
    let session: URLSession
    private var refreshing: Task<String?, Error>?

    public init(store: any CredentialStore, config: OAuthConfig?, session: URLSession = .shared) {
        self.store = store
        self.config = config
        self.session = session
    }

    public var credentials: Credentials? { store.load() }

    public func accessToken() async throws -> String {
        guard let token = store.load()?.accessToken else { throw NotionError.unauthorized }
        return token
    }

    public func refreshAfterUnauthorized(failedToken: String) async throws -> String? {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.refresh(failedToken: failedToken) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    func refresh(failedToken: String) async throws -> String? {
        guard let current = store.load() else { return nil }
        // 다른 프로세스(위젯↔앱)가 이미 갱신했다면 그 토큰을 쓴다. refresh 토큰은 한 번 쓰면 바뀐다.
        if current.accessToken != failedToken { return current.accessToken }
        guard current.kind == .oauth, let refreshToken = current.refreshToken, let config else { return nil }
        do {
            let token = try await post(config.authBaseURL.appending(path: "refresh"), ["refresh_token": refreshToken])
            var next = Credentials(oauth: token)
            next.ownerUserId = next.ownerUserId ?? current.ownerUserId
            next.ownerName = next.ownerName ?? current.ownerName
            next.workspaceName = next.workspaceName ?? current.workspaceName
            try store.save(next)
            return next.accessToken
        } catch {
            // 경쟁에서 진 경우: 그사이 저장된 새 토큰이 있으면 그것을 쓴다.
            if let latest = store.load(), latest.accessToken != failedToken { return latest.accessToken }
            return nil
        }
    }

    /// `ASWebAuthenticationSession`이 돌려준 콜백 URL로 로그인을 마친다.
    public func completeSignIn(callback: URL, pkce: PKCE) async throws -> Credentials {
        guard let config else { throw AuthError.exchangeFailed("OAuth not configured") }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value { throw AuthError.exchangeFailed(error) }
        guard items.first(where: { $0.name == "state" })?.value == pkce.state else { throw AuthError.stateMismatch }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw AuthError.missingCode }
        let token = try await post(
            config.authBaseURL.appending(path: "token"),
            ["code": code, "state": pkce.state, "code_verifier": pkce.verifier])
        let credentials = Credentials(oauth: token)
        try store.save(credentials)
        return credentials
    }

    /// internal integration 토큰으로 로그인 (직접 빌드용 대체 경로). 토큰이 맞는지 `users/me`로 확인한다.
    public func signIn(internalToken: String) async throws -> Credentials {
        let trimmed = internalToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = NotionClient(tokens: StaticTokenProvider(trimmed), session: session)
        let me = try await client.me()
        let credentials = Credentials(
            kind: .internalToken, accessToken: trimmed, ownerUserId: me.bot?.owner?.user?.id,
            ownerName: me.bot?.owner?.user?.name ?? me.name, workspaceName: me.bot?.workspaceName)
        try store.save(credentials)
        return credentials
    }

    public func signOut() {
        store.delete()
    }

    func post(_ url: URL, _ body: [String: String]) async throws -> OAuthToken {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.exchangeFailed(String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(OAuthToken.self, from: data)
    }
}
