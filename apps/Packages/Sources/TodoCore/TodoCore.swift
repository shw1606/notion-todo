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

    public init(configuration: AppConfiguration, credentials: (any CredentialStore)? = nil, store: SharedStore? = nil) {
        self.configuration = configuration
        let credentialStore = credentials ?? KeychainCredentialStore(accessGroup: configuration.keychainGroup)
        auth = AuthSession(store: credentialStore, config: configuration.oauth)
        repository = TodoRepository(
            client: NotionClient(tokens: auth),
            store: store ?? .appGroup(configuration.appGroupId),
            auth: auth)
    }

    public static let shared: TodoServices = {
        #if DEBUG
            // 개발·UI 테스트: NT_DEV_TOKEN이 있으면 Keychain을 건드리지 않는다.
            // (서명이 바뀐 개발 빌드가 로그인 키체인을 읽으면 macOS가 허용 창을 띄우고 멈춘다.)
            if let token = ProcessInfo.processInfo.environment["NT_DEV_TOKEN"], !token.isEmpty {
                return TodoServices(
                    configuration: .fromBundle(),
                    credentials: InMemoryCredentialStore(Credentials(kind: .internalToken, accessToken: token)))
            }
        #endif
        return TodoServices(configuration: .fromBundle())
    }()

    public var isSignedIn: Bool {
        get async { await auth.credentials != nil }
    }
}
