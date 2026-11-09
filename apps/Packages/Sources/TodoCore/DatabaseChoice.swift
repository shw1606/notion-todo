import Foundation
import NotionKit

/// 연결 직후 고를 수 있는 DB 하나 (PLAN 3.2). 검색 한 번으로 만들고, 뷰는 고른 다음에 받는다.
/// 큰 워크스페이스에서도 첫 화면이 바로 뜬다.
public struct DatabaseChoice: Identifiable, Hashable, Sendable {
    /// data source ID
    public var id: String
    public var title: String
    /// 뷰 필터 없이 스키마만 보고 정한 체크 대상. 체크박스·status가 여럿이라 뷰마다 다르면 nil.
    public var completionTarget: CompletionTarget?
    /// 이 앱이 만든 메모 DB ("할 일 메모"·"Memo Todos").
    public var isStarter: Bool

    /// 체크할 칸(체크박스·status)이 없는 DB는 할 일 목록 후보가 아니다.
    public init?(_ source: DataSource) {
        let properties = Array(source.properties.values)
        guard properties.contains(where: { $0.type == "checkbox" || $0.type == "status" }) else { return nil }
        id = source.id
        title = source.title.plainText
        let (completion, _, _) = ViewResolver.inferCompletion(conditions: [], properties: properties)
        completionTarget = ViewResolver.completionTarget(completion, properties: properties)
        isStarter = StarterTemplate.all.contains { $0.databaseTitle == source.title.plainText }
    }
}

extension TodoRepository {
    /// 할 일 목록으로 쓸 만한 DB: 이 앱이 만든 메모 DB 먼저, 나머지는 최근에 고친 순.
    public func databaseChoices() async throws -> [DatabaseChoice] {
        let sources = try await client.searchDataSources(limit: Self.catalogLimit)
        let choices = sources.filter { $0.inTrash != true }.compactMap(DatabaseChoice.init)
        return choices.filter(\.isStarter) + choices.filter { !$0.isStarter }
    }

    /// 고른 DB의 뷰를 받아 캐시에 넣고, 할 일을 보여주는 뷰를 돌려준다.
    public func startingView(dataSourceId: String) async throws -> ViewSummary {
        let source = try await client.dataSource(dataSourceId)
        let views = try await Self.listableViews(of: source, client: client)
        guard let start = views.map(\.summary).preferredDefault else { throw TodoError.noView }
        for view in views { try? store.save(view: view) }
        addToCatalog(views.map(\.summary))
        rememberLastView(start.id)
        return start
    }
}
