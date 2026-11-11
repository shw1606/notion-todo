import Foundation
import NotionKit

/// 앱과 위젯이 함께 쓰는 App Group 컨테이너 안의 파일 캐시.
///
/// 보호 등급은 `completeUntilFirstUserAuthentication`: 잠긴 상태에서도 위젯 체크가 읽고 써야 하므로
/// `complete`를 쓰면 안 된다 (PLAN 4.5).
public struct SharedStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// App Group 컨테이너. 그룹이 없거나(서명 없는 빌드·테스트) 쓸 수 없으면 앱 전용 Application Support로 대체한다.
    public static func appGroup(_ identifier: String?) -> SharedStore {
        // macOS는 권한이 없어도 그룹 경로를 돌려주므로 실제로 쓸 수 있는지 확인한다.
        if let identifier,
            let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        {
            let root = url.appending(path: "NotionTodo", directoryHint: .isDirectory)
            if (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)) != nil {
                return SharedStore(root: root)
            }
        }
        let support = URL.applicationSupportDirectory.appending(path: "NotionTodo", directoryHint: .isDirectory)
        return SharedStore(root: support)
    }

    // MARK: 파일 위치

    func url(_ path: String) -> URL { root.appending(path: path) }
    static func safe(_ id: String) -> String { NotionID.compact(id) }

    func viewURL(_ id: String) -> URL { url("views/\(Self.safe(id)).json") }
    func itemsURL(_ id: String) -> URL { url("items/\(Self.safe(id)).json") }
    func layoutURL(_ id: String) -> URL { url("layouts/\(Self.safe(id)).json") }
    var catalogURL: URL { url("catalog.json") }
    var pendingURL: URL { url("pending.json") }
    var settingsURL: URL { url("settings.json") }

    // MARK: 읽기·쓰기

    func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    func write<T: Encodable>(_ value: T, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: url, options: .atomic)
        #endif
    }

    func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: 형식별 접근

    public func view(_ id: String) -> ResolvedView? { read(ResolvedView.self, at: viewURL(id)) }
    public func save(view: ResolvedView) throws { try write(view, at: viewURL(view.id)) }

    public func items(_ viewId: String) -> ItemsSnapshot? { read(ItemsSnapshot.self, at: itemsURL(viewId)) }
    public func save(items: ItemsSnapshot) throws { try write(items, at: itemsURL(items.viewId)) }

    /// 뷰의 로컬 배치(순서·섹션). 없으면 nil.
    public func layout(_ viewId: String) -> ViewLayout? { read(ViewLayout.self, at: layoutURL(viewId)) }
    public func save(layout: ViewLayout, viewId: String) throws { try write(layout, at: layoutURL(viewId)) }
    public func removeLayout(_ viewId: String) { remove(at: layoutURL(viewId)) }
    /// 모든 뷰의 배치를 지운다 (개발·UI 테스트).
    public func removeAllLayouts() { remove(at: url("layouts")) }

    public func catalog() -> ViewCatalog? { read(ViewCatalog.self, at: catalogURL) }
    public func save(catalog: ViewCatalog) throws { try write(catalog, at: catalogURL) }

    public func pending() -> [PendingOperation] { read([PendingOperation].self, at: pendingURL) ?? [] }
    public func save(pending: [PendingOperation]) throws { try write(pending, at: pendingURL) }

    public func settings() -> AppSettings { read(AppSettings.self, at: settingsURL) ?? AppSettings() }
    public func save(settings: AppSettings) throws { try write(settings, at: settingsURL) }

    /// 로그아웃: 캐시 전체 삭제.
    public func wipe() {
        remove(at: root)
    }
}

public struct ViewCatalog: Codable, Hashable, Sendable {
    public var views: [ViewSummary]
    public var fetchedAt: Date

    public init(views: [ViewSummary], fetchedAt: Date) {
        self.views = views
        self.fetchedAt = fetchedAt
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    /// 앱 메인 화면에 마지막으로 연 뷰. 위젯 설정이 비었을 때도 기본값이 된다.
    public var lastViewId: String?
    /// 앱 목록·위젯 설정에 올릴 DB(data source ID), 고른 순서대로. nil이면 이 값을 기록하기 전 버전에서 올라왔다.
    public var databaseIds: [String]?
    /// Mac 메뉴 막대 빠른 기록 표시.
    public var showsMenuBarExtra: Bool = true

    public init(lastViewId: String? = nil, databaseIds: [String]? = nil, showsMenuBarExtra: Bool = true) {
        self.lastViewId = lastViewId
        self.databaseIds = databaseIds
        self.showsMenuBarExtra = showsMenuBarExtra
    }
}

/// 아직 Notion에 보내지 못한 쓰기. 오프라인·실패 시 쌓였다가 앱 활성화·위젯 갱신 때 보낸다.
public struct PendingOperation: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: Codable, Hashable, Sendable {
        case setDone(pageId: String, done: Bool)
        case create(localId: String, title: String)
        case rename(pageId: String, title: String)
        case trash(pageId: String)
    }

    public var id: UUID
    public var viewId: String
    public var kind: Kind
    public var createdAt: Date
    public var attempts: Int

    public init(viewId: String, kind: Kind, id: UUID = UUID(), createdAt: Date = .now, attempts: Int = 0) {
        self.id = id
        self.viewId = viewId
        self.kind = kind
        self.createdAt = createdAt
        self.attempts = attempts
    }

    public var pageId: String? {
        switch kind {
        case .setDone(let id, _), .rename(let id, _), .trash(let id): id
        case .create(let id, _): id
        }
    }
}
