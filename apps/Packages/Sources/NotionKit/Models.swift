import Foundation

// Notion API 응답 중 앱이 쓰는 부분만 좁게 디코딩한다. 나머지 필드는 무시한다.

public struct RichText: Codable, Hashable, Sendable {
    public var plainText: String

    enum CodingKeys: String, CodingKey { case plainText = "plain_text" }

    public init(_ text: String) { plainText = text }
}

extension [RichText] {
    public var plainText: String { map(\.plainText).joined() }
}

public enum Parent: Codable, Hashable, Sendable {
    case workspace
    case page(String)
    case database(String)
    case dataSource(id: String, databaseId: String?)
    case block(String)
    case other(String)

    enum CodingKeys: String, CodingKey {
        case type
        case pageId = "page_id"
        case databaseId = "database_id"
        case dataSourceId = "data_source_id"
        case blockId = "block_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "workspace": self = .workspace
        case "page_id": self = .page(try c.decode(String.self, forKey: .pageId))
        case "database_id": self = .database(try c.decode(String.self, forKey: .databaseId))
        case "data_source_id":
            self = .dataSource(
                id: try c.decode(String.self, forKey: .dataSourceId),
                databaseId: try c.decodeIfPresent(String.self, forKey: .databaseId))
        case "block_id": self = .block(try c.decode(String.self, forKey: .blockId))
        default: self = .other(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .workspace: try c.encode("workspace", forKey: .type)
        case .page(let id): try c.encode("page_id", forKey: .type); try c.encode(id, forKey: .pageId)
        case .database(let id): try c.encode("database_id", forKey: .type); try c.encode(id, forKey: .databaseId)
        case .dataSource(let id, let db):
            try c.encode("data_source_id", forKey: .type)
            try c.encode(id, forKey: .dataSourceId)
            try c.encodeIfPresent(db, forKey: .databaseId)
        case .block(let id): try c.encode("block_id", forKey: .type); try c.encode(id, forKey: .blockId)
        case .other(let t): try c.encode(t, forKey: .type)
        }
    }
}

public struct ListResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    public var results: [Item]
    public var nextCursor: String?
    public var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case results
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

public struct ObjectRef: Decodable, Hashable, Sendable {
    public var id: String
}

// MARK: - Users

public struct NotionUser: Codable, Hashable, Sendable {
    public var id: String
    public var name: String?
    public var type: String?
    public var bot: Bot?

    public struct Bot: Codable, Hashable, Sendable {
        public var owner: Owner?
        public var workspaceName: String?

        enum CodingKeys: String, CodingKey {
            case owner
            case workspaceName = "workspace_name"
        }
    }

    public struct Owner: Codable, Hashable, Sendable {
        public var type: String
        public var user: Person?
        public init(type: String, user: Person?) { self.type = type; self.user = user }
    }

    /// 봇의 주인 등, 다시 봇 정보를 갖지 않는 사람 사용자.
    public struct Person: Codable, Hashable, Sendable {
        public var id: String
        public var name: String?
        public init(id: String, name: String?) { self.id = id; self.name = name }
    }
}

// MARK: - Databases / data sources

public struct Database: Decodable, Hashable, Sendable {
    public var id: String
    public var title: [RichText]
    public var url: String?
    public var dataSources: [DataSourceRef]
    public var inTrash: Bool?

    public struct DataSourceRef: Decodable, Hashable, Sendable {
        public var id: String
        public var name: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, title, url
        case dataSources = "data_sources"
        case inTrash = "in_trash"
    }
}

public struct DataSource: Decodable, Hashable, Sendable {
    public var id: String
    public var title: [RichText]
    public var url: String?
    public var parent: Parent?
    public var properties: [String: PropertySchema]
    public var inTrash: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, url, parent, properties
        case inTrash = "in_trash"
    }

    public init(
        id: String, title: [RichText], url: String? = nil, parent: Parent? = nil,
        properties: [String: PropertySchema], inTrash: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.parent = parent
        self.properties = properties
        self.inTrash = inTrash
    }

    /// `parent`가 `database_id`면 그 DB의 ID.
    public var databaseId: String? {
        if case .database(let id) = parent { return id }
        return nil
    }
}

public struct PropertySchema: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    public var status: StatusSchema?

    public init(id: String, name: String, type: String, status: StatusSchema? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.status = status
    }
}

public struct StatusSchema: Codable, Hashable, Sendable {
    public var options: [Option]
    public var groups: [Group]

    public struct Option: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    public struct Group: Codable, Hashable, Sendable {
        public var id: String?
        public var name: String
        public var optionIds: [String]

        enum CodingKeys: String, CodingKey {
            case id, name
            case optionIds = "option_ids"
        }

        public init(name: String, optionIds: [String]) { self.name = name; self.optionIds = optionIds }
    }

    public init(options: [Option], groups: [Group]) {
        self.options = options
        self.groups = groups
    }

    /// Status 그룹 이름은 API에서 To-do / In progress / Complete로 고정이다.
    public func optionIds(inGroup name: String) -> [String] {
        groups.first { $0.name == name }?.optionIds ?? []
    }

    public func option(id: String) -> Option? { options.first { $0.id == id } }
    public func option(named name: String) -> Option? { options.first { $0.name == name } }
}

// MARK: - Pages

public struct Page: Decodable, Hashable, Sendable {
    public var id: String
    public var url: String?
    public var createdTime: String?
    public var lastEditedTime: String?
    public var inTrash: Bool?
    public var parent: Parent?
    public var properties: [String: PropertyValue]

    enum CodingKeys: String, CodingKey {
        case id, url, parent, properties
        case createdTime = "created_time"
        case lastEditedTime = "last_edited_time"
        case inTrash = "in_trash"
    }

    public init(
        id: String, url: String? = nil, createdTime: String? = nil, lastEditedTime: String? = nil,
        inTrash: Bool? = nil, parent: Parent? = nil, properties: [String: PropertyValue]
    ) {
        self.id = id
        self.url = url
        self.createdTime = createdTime
        self.lastEditedTime = lastEditedTime
        self.inTrash = inTrash
        self.parent = parent
        self.properties = properties
    }

    public var titleText: String {
        properties.values.first { $0.type == "title" }?.title?.plainText ?? ""
    }
}

public struct PropertyValue: Decodable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var title: [RichText]?
    public var checkbox: Bool?
    public var status: StatusSchema.Option?
    public var date: DateValue?

    public struct DateValue: Codable, Hashable, Sendable {
        public var start: String
        public var end: String?
        public init(start: String, end: String? = nil) { self.start = start; self.end = end }
    }

    public init(
        id: String, type: String, title: [RichText]? = nil, checkbox: Bool? = nil,
        status: StatusSchema.Option? = nil, date: DateValue? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.checkbox = checkbox
        self.status = status
        self.date = date
    }

    enum CodingKeys: String, CodingKey { case id, type, title, checkbox, status, date }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        // 값이 null이거나 형태가 달라도 페이지 전체 디코딩이 실패하지 않게 한다.
        title = try? c.decodeIfPresent([RichText].self, forKey: .title)
        checkbox = try? c.decodeIfPresent(Bool.self, forKey: .checkbox)
        status = try? c.decodeIfPresent(StatusSchema.Option.self, forKey: .status)
        date = try? c.decodeIfPresent(DateValue.self, forKey: .date)
    }
}

// MARK: - Views

public struct NotionView: Decodable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    public var parent: Parent?
    public var dataSourceId: String?
    public var url: String?
    public var filter: JSONValue?
    public var sorts: JSONValue?
    public var quickFilters: [String: JSONValue]?
    public var lastEditedTime: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type, parent, url, filter, sorts
        case dataSourceId = "data_source_id"
        case quickFilters = "quick_filters"
        case lastEditedTime = "last_edited_time"
    }

    public init(
        id: String, name: String, type: String = "table", parent: Parent? = nil, dataSourceId: String?,
        url: String? = nil, filter: JSONValue? = nil, sorts: JSONValue? = nil,
        quickFilters: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.parent = parent
        self.dataSourceId = dataSourceId
        self.url = url
        self.filter = filter
        self.sorts = sorts
        self.quickFilters = quickFilters
    }

    public var databaseId: String? {
        if case .database(let id) = parent { return id }
        return nil
    }

    /// 위젯에 쓸 수 있는 뷰인가. 대시보드(data source 없음)와 목록이 아닌 형태는 뺀다.
    public var isListable: Bool {
        guard dataSourceId != nil else { return false }
        return !["dashboard", "form", "chart", "map"].contains(type)
    }
}

// MARK: - OAuth

public struct OAuthToken: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var botId: String?
    public var workspaceId: String?
    public var workspaceName: String?
    public var owner: NotionUser.Owner?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case botId = "bot_id"
        case workspaceId = "workspace_id"
        case workspaceName = "workspace_name"
        case owner
    }

    public init(
        accessToken: String, refreshToken: String? = nil, botId: String? = nil, workspaceId: String? = nil,
        workspaceName: String? = nil, owner: NotionUser.Owner? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.botId = botId
        self.workspaceId = workspaceId
        self.workspaceName = workspaceName
        self.owner = owner
    }
}

// MARK: - ID 정규화

public enum NotionID {
    /// 대시 유무·대소문자를 무시하고 비교할 수 있는 형태.
    public static func compact(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// 속성 ID는 스키마에서는 퍼센트 인코딩(`%3BQFf`), 뷰 필터에서는 디코딩(`;QFf`) 형태로 온다.
    public static func property(_ id: String) -> String {
        id.removingPercentEncoding ?? id
    }

    /// URL 또는 ID 문자열에서 32자리 ID를 뽑는다.
    public static func extract(from text: String) -> String? {
        let pattern = #"[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return compact(String(text[range]))
    }
}
