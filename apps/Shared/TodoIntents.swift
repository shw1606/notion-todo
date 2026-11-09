import AppIntents
import Foundation
import TodoCore
import WidgetKit

// 앱·위젯 확장 양쪽에 컴파일된다 (PLAN 5.5).

// MARK: - 뷰 엔티티

/// 위젯 편집에서 고르는 Notion 뷰.
struct NotionViewEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Notion View"
    static let defaultQuery = NotionViewQuery()

    var id: String
    var name: String
    var databaseTitle: String

    init(_ summary: ViewSummary) {
        id = summary.id
        name = summary.name
        databaseTitle = summary.databaseTitle
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(databaseTitle)")
    }
}

struct NotionViewQuery: EntityQuery {
    /// 앱 목록에서 뺀 DB의 뷰라도 이미 그 뷰를 보여주는 위젯은 그대로 둔다 (캐시된 뷰 정의로 찾는다).
    func entities(for identifiers: [String]) async throws -> [NotionViewEntity] {
        let repository = TodoServices.shared.repository
        let catalog = await repository.cachedCatalog()
        var entities: [NotionViewEntity] = []
        for id in identifiers {
            if let summary = catalog.first(where: { $0.id == id }) {
                entities.append(NotionViewEntity(summary))
            } else if let view = await repository.store.view(id) {
                entities.append(NotionViewEntity(view.summary))
            }
        }
        return entities
    }

    /// 캐시된 목록을 바로 주고 뒤에서 새로 받아 둔다. 캐시가 비었으면 Notion에서 받아 온다.
    func suggestedEntities() async throws -> [NotionViewEntity] {
        let repository = TodoServices.shared.repository
        let cached = await repository.cachedCatalog()
        guard !cached.isEmpty else { return ((try? await repository.catalog()) ?? []).map(NotionViewEntity.init) }
        Task { _ = try? await repository.catalog(refresh: true) }
        return cached.map(NotionViewEntity.init)
    }

    func defaultResult() async -> NotionViewEntity? {
        await TodoServices.shared.repository.cachedCatalog().preferredDefault.map(NotionViewEntity.init)
    }
}

// MARK: - 위젯 설정

struct SelectViewIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose View"
    static let description = IntentDescription("Pick the Notion view this widget shows.")

    @Parameter(title: "View")
    var view: NotionViewEntity?

    init() {}

    init(view: NotionViewEntity?) {
        self.view = view
    }
}

// MARK: - 체크

/// 위젯·잠금화면의 체크 버튼. 잠금 해제 없이 동작하도록 허용하는 유일한 인텐트다 (DECISIONS 2026-11-09).
struct ToggleTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Memo"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Memo ID") var itemId: String
    @Parameter(title: "View ID") var viewId: String
    @Parameter(title: "Done") var done: Bool

    init() {}

    init(itemId: String, viewId: String, done: Bool) {
        self.itemId = itemId
        self.viewId = viewId
        self.done = done
    }

    func perform() async throws -> some IntentResult {
        // 실패해도 대기열에 남아 다음 기회에 보내진다. 위젯은 캐시의 낙관적 상태로 다시 그린다.
        try? await TodoServices.shared.repository.setDone(viewId: viewId, itemId: itemId, done: done)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - 다시 시도

struct RefreshWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh"
    static let isDiscoverable = false

    @Parameter(title: "View ID") var viewId: String?

    init() {}

    init(viewId: String?) {
        self.viewId = viewId
    }

    func perform() async throws -> some IntentResult {
        let repository = TodoServices.shared.repository
        if let viewId { _ = try? await repository.fetchItems(viewId) }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - 추가 (Siri·단축어)

struct AddMemoIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Memo"
    static let description = IntentDescription("Adds a memo to your Notion todo view without opening the app.")

    @Parameter(title: "Memo", requestValueDialog: "What do you want to write down?")
    var text: String

    @Parameter(title: "View")
    var view: NotionViewEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$view)")
    }

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let repository = TodoServices.shared.repository
        var chosen = view?.id
        if chosen == nil { chosen = await repository.defaultViewId() }
        guard let viewId = chosen else { throw AddMemoError.noView }
        try await repository.add(viewId: viewId, title: text)
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "Added “\(text)”.")
    }
}

enum AddMemoError: Error, CustomLocalizedStringResourceConvertible {
    case noView

    var localizedStringResource: LocalizedStringResource {
        "Open Todo Widget and choose a database first."
    }
}

// MARK: - 딥링크

enum DeepLink {
    static let scheme = "notiontodo"

    /// 입력 바에 커서를 둔 채 앱을 연다. 제어 위젯·위젯 `+` 버튼이 쓴다.
    static func compose(viewId: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "compose"
        if let viewId { components.queryItems = [URLQueryItem(name: "view", value: viewId)] }
        return components.url!
    }

    static func view(_ id: String) -> URL {
        URL(string: "\(scheme)://view?id=\(id)")!
    }

    static let onboarding = URL(string: "\(scheme)://onboarding")!

    enum Action: Equatable {
        case compose(viewId: String?)
        case view(String)
        case onboarding
    }

    static func parse(_ url: URL) -> Action? {
        guard url.scheme == scheme else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host() {
        case "compose": return .compose(viewId: items.first { $0.name == "view" }?.value)
        case "view": return items.first { $0.name == "id" }?.value.map(Action.view)
        case "onboarding": return .onboarding
        default: return nil
        }
    }
}
