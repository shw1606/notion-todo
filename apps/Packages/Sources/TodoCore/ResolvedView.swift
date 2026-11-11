import Foundation
import NotionKit

/// 체크했을 때 무엇을 바꾸는가.
public enum CompletionStrategy: Codable, Hashable, Sendable {
    /// checkbox 속성을 뒤집는다.
    case checkbox(propertyId: String)
    /// status 속성을 Complete 그룹 첫 옵션(완료) ↔ To-do 그룹 첫 옵션(되돌리기)으로 바꾼다.
    case status(propertyId: String, doneOptionId: String, undoOptionId: String, completeOptionIds: [String])
    /// 완료 속성을 정할 수 없다. 표시만 한다.
    case readOnly(ReadOnlyReason)

    public var isWritable: Bool {
        if case .readOnly = self { return false }
        return true
    }

    public var propertyId: String? {
        switch self {
        case .checkbox(let id), .status(let id, _, _, _): id
        case .readOnly: nil
        }
    }
}

/// 체크하면 무엇이 바뀌는지 사람이 읽을 이름으로. 온보딩에서 뷰마다 한 줄로 알려준다 (PLAN 3.2).
public enum CompletionTarget: Codable, Hashable, Sendable {
    /// "완료"에 체크된다.
    case checkbox(propertyName: String)
    /// "상태"가 "Done"이 된다.
    case status(propertyName: String, doneOptionName: String)
}

public enum ReadOnlyReason: String, Codable, Hashable, Sendable {
    /// checkbox·status 속성이 없다.
    case noCompletionProperty
    /// 후보가 여러 개인데 뷰 필터로 고를 수 없다.
    case ambiguous
}

/// 새 항목이 뷰 조건을 만족하도록 채울 값. "me"·"today"처럼 만드는 시점에 계산해야 하는 값이 있어 규칙으로 둔다.
public enum CreateRule: Codable, Hashable, Sendable {
    case checkbox(propertyId: String, value: Bool)
    case statusName(propertyId: String, name: String)
    case selectName(propertyId: String, name: String)
    case multiSelectName(propertyId: String, name: String)
    case peopleMe(propertyId: String)
    case date(propertyId: String, value: String)
}

/// 뷰 정의를 해석한 결과. 위젯·앱이 매번 Notion에 뷰 정의를 묻지 않도록 캐시한다.
public struct ResolvedView: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var databaseId: String?
    public var dataSourceId: String
    public var databaseTitle: String
    public var url: String?
    /// `filter`와 `quick_filters`를 AND로 합친 것.
    public var filter: JSONValue?
    public var sorts: JSONValue?
    public var titlePropertyId: String
    public var completion: CompletionStrategy
    public var datePropertyId: String?
    /// 이 뷰가 완료된 항목을 보여주는 뷰인가 ("완료함" 같은 뷰).
    public var showsDone: Bool
    /// 뷰 필터가 완료 속성으로 거른다 → 체크하면 뷰에서 빠진다. false면 체크해도 남는다(취소선 표시).
    public var filtersByCompletion: Bool
    public var createRules: [CreateRule]
    public var resolvedAt: Date
    /// 읽기 전용이거나 이 필드가 생기기 전의 캐시면 nil.
    public var completionTarget: CompletionTarget? = nil

    public var summary: ViewSummary {
        ViewSummary(
            id: id, name: name, databaseId: databaseId, dataSourceId: dataSourceId, databaseTitle: databaseTitle,
            isWritable: completion.isWritable, showsDone: showsDone, completionTarget: completionTarget)
    }

    /// data source 쿼리 본문. 위젯 갱신당 이 요청 1회만 보낸다.
    public func queryBody(pageSize: Int = 100) -> JSONValue {
        var body: [String: JSONValue] = ["page_size": .number(Double(pageSize))]
        if let filter { body["filter"] = filter }
        if let sorts, let array = sorts.arrayValue, !array.isEmpty { body["sorts"] = sorts }
        return .object(body)
    }

    /// 항목을 만드는 데 읽는 속성 (제목·완료·날짜). 쿼리에서 이것만 받는다.
    public var queryPropertyIds: [String] {
        var ids = [titlePropertyId]
        for case let id? in [completion.propertyId, datePropertyId] where !ids.contains(id) { ids.append(id) }
        return ids
    }
}

/// 뷰 고르기 목록에 쓰는 요약.
public struct ViewSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var databaseId: String?
    public var dataSourceId: String
    public var databaseTitle: String
    public var isWritable: Bool
    public var showsDone: Bool
    public var completionTarget: CompletionTarget?

    public init(
        id: String, name: String, databaseId: String?, dataSourceId: String, databaseTitle: String,
        isWritable: Bool, showsDone: Bool, completionTarget: CompletionTarget? = nil
    ) {
        self.id = id
        self.name = name
        self.databaseId = databaseId
        self.dataSourceId = dataSourceId
        self.databaseTitle = databaseTitle
        self.isWritable = isWritable
        self.showsDone = showsDone
        self.completionTarget = completionTarget
    }

    /// 위젯 기본값으로 쓸 만한 뷰인가: 체크할 수 있고, 아직 안 한 일을 보여준다.
    public var isGoodDefault: Bool { isWritable && !showsDone }
}

extension [ViewSummary] {
    /// API의 뷰 목록 순서는 Notion 탭 순서와 다르다. 그래서 "첫 번째 뷰" 대신 할 일을 보여주는 뷰를 고른다.
    public var preferredDefault: ViewSummary? {
        first(where: \.isGoodDefault) ?? first(where: \.isWritable) ?? first
    }

    /// DB별로 묶는다 (사이드바·설정). DB와 뷰의 순서는 목록 순서 그대로.
    public var byDatabase: [DatabaseViews] {
        var groups: [DatabaseViews] = []
        for view in self {
            if let i = groups.firstIndex(where: { NotionID.compact($0.id) == NotionID.compact(view.dataSourceId) }) {
                groups[i].views.append(view)
            } else {
                groups.append(DatabaseViews(id: view.dataSourceId, title: view.databaseTitle, views: [view]))
            }
        }
        return groups
    }
}

/// 고른 DB 하나와 그 뷰들.
public struct DatabaseViews: Identifiable, Hashable, Sendable {
    /// data source ID
    public var id: String
    public var title: String
    public var views: [ViewSummary]
}

/// 한 번 조회한 결과.
public struct ItemsSnapshot: Codable, Hashable, Sendable {
    public var viewId: String
    public var items: [TodoItem]
    public var hasMore: Bool
    public var fetchedAt: Date

    public init(viewId: String, items: [TodoItem], hasMore: Bool, fetchedAt: Date) {
        self.viewId = viewId
        self.items = items
        self.hasMore = hasMore
        self.fetchedAt = fetchedAt
    }

    public var remainingCount: Int { items.filter { !$0.isDone }.count }
}

public struct TodoItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var isDone: Bool
    /// 날짜 속성의 시작값 (`2026-11-10` 또는 ISO 8601 시각).
    public var due: String?
    public var url: String?
    public var createdTime: String?
    /// 아직 Notion에 반영되지 않은 로컬 변경이 있다.
    public var isPending: Bool

    public init(
        id: String, title: String, isDone: Bool, due: String? = nil, url: String? = nil, createdTime: String? = nil,
        isPending: Bool = false
    ) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.due = due
        self.url = url
        self.createdTime = createdTime
        self.isPending = isPending
    }

    /// 로컬에서 만들어 아직 Notion ID가 없는 항목.
    public var isLocalOnly: Bool { id.hasPrefix(TodoItem.localPrefix) }
    static let localPrefix = "local-"
}
