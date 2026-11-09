import Foundation
import NotionKit

/// README의 "기본 예시 DB": 내용 · 완료 · 만든 시간, 뷰 "할 일"(미완료)·"완료함".
public struct StarterTemplate: Sendable, Hashable {
    public var databaseTitle: String
    public var emoji: String
    public var titleProperty: String
    public var doneProperty: String
    public var createdProperty: String
    public var todoView: String
    public var doneView: String

    public static let korean = StarterTemplate(
        databaseTitle: "할 일 메모", emoji: "📝", titleProperty: "내용", doneProperty: "완료", createdProperty: "만든 시간",
        todoView: "할 일", doneView: "완료함")

    public static let english = StarterTemplate(
        databaseTitle: "Memo Todos", emoji: "📝", titleProperty: "Memo", doneProperty: "Done",
        createdProperty: "Created", todoView: "To do", doneView: "Done")

    /// 기기 언어가 한국어면 한국어 이름으로 만든다.
    public static var forCurrentLocale: StarterTemplate {
        Locale.preferredLanguages.first?.hasPrefix("ko") == true ? .korean : .english
    }
}

extension TodoRepository {
    /// 선택한 페이지 아래에 기본 예시 DB를 만들고 "할 일" 뷰 요약을 돌려준다.
    public func createStarterDatabase(parentPageId: String, template: StarterTemplate = .forCurrentLocale)
        async throws -> ViewSummary
    {
        let database = try await client.createDatabase(
            parentPageId: parentPageId, title: template.databaseTitle, emoji: template.emoji,
            properties: [
                template.titleProperty: ["title": [:]],
                template.doneProperty: ["checkbox": [:]],
                template.createdProperty: ["created_time": [:]],
            ])
        guard let dataSourceId = database.dataSources.first?.id else { throw NotionError.notFound }
        let notDone: JSONValue = ["property": .string(template.doneProperty), "checkbox": ["equals": false]]
        let done: JSONValue = ["property": .string(template.doneProperty), "checkbox": ["equals": true]]
        // 정렬은 created_time "속성"으로 건다. 뷰에 timestamp 정렬을 넣으면 API가 저장하지 않는다.
        let newestFirst: JSONValue = [["property": .string(template.createdProperty), "direction": "descending"]]

        // DB를 만들면 기본 뷰가 하나 생긴다 → "할 일"로 바꾸고 "완료함"을 추가한다.
        let todoViewId: String
        if let defaultViewId = try await client.viewIds(dataSourceId: dataSourceId).first {
            todoViewId = try await client.updateView(
                defaultViewId, body: ["name": .string(template.todoView), "filter": notDone, "sorts": newestFirst]
            ).id
        } else {
            todoViewId = try await client.createView(
                databaseId: database.id, dataSourceId: dataSourceId, name: template.todoView,
                body: ["filter": notDone, "sorts": newestFirst]
            ).id
        }
        _ = try await client.createView(
            databaseId: database.id, dataSourceId: dataSourceId, name: template.doneView,
            body: ["filter": done, "sorts": newestFirst])

        let resolved = try await resolvedView(todoViewId, refresh: true)
        _ = try? await catalog(refresh: true)
        rememberLastView(resolved.id)
        return resolved.summary
    }
}
