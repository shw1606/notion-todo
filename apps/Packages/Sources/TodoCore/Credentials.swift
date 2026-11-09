import Foundation
import NotionKit
import Security

public struct Credentials: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// "Notion으로 로그인" — 토큰 교환 함수를 통해 받은 토큰. 갱신할 수 있다.
        case oauth
        /// 직접 빌드하는 사용자가 붙여 넣은 internal integration 토큰.
        case internalToken
    }

    public var kind: Kind
    public var accessToken: String
    public var refreshToken: String?
    public var ownerUserId: String?
    public var ownerName: String?
    public var workspaceName: String?

    public init(
        kind: Kind, accessToken: String, refreshToken: String? = nil, ownerUserId: String? = nil,
        ownerName: String? = nil, workspaceName: String? = nil
    ) {
        self.kind = kind
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.ownerUserId = ownerUserId
        self.ownerName = ownerName
        self.workspaceName = workspaceName
    }

    public init(oauth token: OAuthToken) {
        self.init(
            kind: .oauth, accessToken: token.accessToken, refreshToken: token.refreshToken,
            ownerUserId: token.owner?.user?.id, ownerName: token.owner?.user?.name,
            workspaceName: token.workspaceName)
    }
}

public protocol CredentialStore: Sendable {
    func load() -> Credentials?
    func save(_ credentials: Credentials) throws
    func delete()
}

/// Keychain 저장. `AfterFirstUnlock`이라 잠긴 상태에서도 위젯이 읽을 수 있다 (PLAN 4.5).
public struct KeychainCredentialStore: CredentialStore {
    let service: String
    let account: String
    let accessGroup: String?

    public init(service: String = "notion-todo", account: String = "credentials", accessGroup: String?) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    func baseQuery(group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    public func load() -> Credentials? {
        for group in candidateGroups {
            var query = baseQuery(group: group)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
                return try? JSONDecoder().decode(Credentials.self, from: data)
            }
        }
        return nil
    }

    public func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        var lastStatus: OSStatus = errSecSuccess
        for group in candidateGroups {
            let query = baseQuery(group: group)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
            }
            if status == errSecSuccess { return }
            lastStatus = status
            // 공유 그룹 권한이 없는 빌드(서명 없음·테스트)면 그룹 없이 다시 시도한다.
            guard status == errSecMissingEntitlement else { break }
        }
        throw KeychainError(status: lastStatus)
    }

    public func delete() {
        for group in candidateGroups { SecItemDelete(baseQuery(group: group) as CFDictionary) }
    }

    var candidateGroups: [String?] { accessGroup == nil ? [nil] : [accessGroup, nil] }
}

public struct KeychainError: Error, Equatable {
    public var status: OSStatus
}

/// 테스트·미리보기용.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Credentials?

    public init(_ value: Credentials? = nil) { self.value = value }
    public func load() -> Credentials? { lock.withLock { value } }
    public func save(_ credentials: Credentials) throws { lock.withLock { value = credentials } }
    public func delete() { lock.withLock { value = nil } }
}
