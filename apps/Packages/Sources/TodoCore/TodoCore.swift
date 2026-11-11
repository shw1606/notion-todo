import Foundation
import NotionKit

/// 앱·위젯 확장이 Info.plist에서 읽는 설정. 값은 `apps/Config/*.xcconfig`에서 들어온다.
public struct AppConfiguration: Sendable, Hashable {
    public var appGroupId: String?
    public var keychainGroup: String?
    public var oauth: OAuthConfig?

    public init(appGroupId: String?, keychainGroup: String?, oauth: OAuthConfig?) {
        self.appGroupId = appGroupId
        self.keychainGroup = keychainGroup
        self.oauth = oauth
    }

    public static func fromBundle(_ bundle: Bundle = .main) -> AppConfiguration {
        func value(_ key: String) -> String? {
            guard let text = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            // 빈 값이거나 xcconfig 변수가 치환되지 않은 경우는 없는 것으로 본다.
            return trimmed.isEmpty || trimmed.contains("$(") ? nil : trimmed
        }
        var oauth: OAuthConfig?
        if let clientId = value("NTOAuthClientID"), let base = value("NTAuthBaseURL").flatMap(URL.init(string:)) {
            oauth = OAuthConfig(clientId: clientId, authBaseURL: base)
        }
        return AppConfiguration(
            appGroupId: value("NTAppGroupID"), keychainGroup: value("NTKeychainGroup"), oauth: oauth)
    }
}

/// 프로세스당 하나. 앱과 위젯 확장이 각자 만들지만 같은 App Group·Keychain을 본다.
public final class TodoServices: Sendable {
    public let configuration: AppConfiguration
    public let auth: AuthSession
    public let repository: TodoRepository

    public init(
        configuration: AppConfiguration, credentials: (any CredentialStore)? = nil, store: SharedStore? = nil,
        session: URLSession = .notion
    ) {
        self.configuration = configuration
        let credentialStore = credentials ?? KeychainCredentialStore(accessGroup: configuration.keychainGroup)
        auth = AuthSession(store: credentialStore, config: configuration.oauth, session: session)
        repository = TodoRepository(
            client: NotionClient(tokens: auth, session: session),
            store: store ?? .appGroup(configuration.appGroupId),
            auth: auth)
    }

    public static let shared: TodoServices = {
        removeLegacyHTTPCache()
        #if DEBUG
            // 개발·UI 테스트: NT_DEV_TOKEN이 있으면 Keychain을 건드리지 않는다.
            // (서명이 바뀐 개발 빌드가 로그인 키체인을 읽으면 macOS가 허용 창을 띄우고 멈춘다.)
            // NT_DEV_OFFLINE=1이면 모든 요청이 "인터넷 연결 없음"으로 실패한다 (오프라인 UI 테스트).
            // NT_DEV_SIGNED_OUT=1이면 로그인 안 한 상태로 시작한다 (온보딩 시험). 연결해도 메모리에만 둔다.
            // NT_DEV_RESET_LAYOUTS=1이면 기기에만 있는 순서·섹션을 지우고 시작한다 (실패한 UI 테스트가 남긴 섹션 정리).
            // NT_DEV_STORE_DIR=<폴더>면 App Group 대신 그 폴더를 저장소로 쓴다 (설치된 앱의 데이터와 섞지 않고 Mac에서 시험).
            let environment = ProcessInfo.processInfo.environment
            let store =
                environment["NT_DEV_STORE_DIR"].map { SharedStore(root: URL(fileURLWithPath: $0, isDirectory: true)) }
                ?? SharedStore.appGroup(AppConfiguration.fromBundle().appGroupId)
            if environment["NT_DEV_RESET_LAYOUTS"] == "1" { store.removeAllLayouts() }
            let session: URLSession = environment["NT_DEV_OFFLINE"] == "1" ? .offline : .notion
            if environment["NT_DEV_SIGNED_OUT"] == "1" {
                return TodoServices(
                    configuration: .fromBundle(), credentials: InMemoryCredentialStore(), store: store, session: session)
            }
            if let token = environment["NT_DEV_TOKEN"], !token.isEmpty {
                return TodoServices(
                    configuration: .fromBundle(),
                    credentials: InMemoryCredentialStore(Credentials(kind: .internalToken, accessToken: token)),
                    store: store, session: session)
            }
        #endif
        return TodoServices(configuration: .fromBundle())
    }()

    public var isSignedIn: Bool {
        get async { await auth.credentials != nil }
    }

    /// 이전 버전이 `URLSession.shared`로 쌓아 둔 HTTP 디스크 캐시(Cache.db, 수 MB)를 지운다. 이제는 만들지 않는다.
    static func removeLegacyHTTPCache() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
            let bundleId = Bundle.main.bundleIdentifier
        else { return }
        let folder = caches.appending(path: bundleId, directoryHint: .isDirectory)
        for name in ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"] {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }
}

#if DEBUG
    extension URLSession {
        static let offline: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OfflineURLProtocol.self]
            return URLSession(configuration: configuration)
        }()
    }

    final class OfflineURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
    }
#endif
