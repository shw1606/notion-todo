import NotionKit
import TodoCore
import WidgetKit

struct TodoEntry: TimelineEntry {
    enum State: Equatable {
        case ready
        case signedOut
        case needsView
        case viewMissing
        case reauth
    }

    var date: Date
    var state: State
    var viewId: String?
    var viewName: String
    var isWritable: Bool
    var items: [TodoItem]
    var hasMore: Bool
    var isOffline: Bool
    var fetchedAt: Date?

    var remaining: Int { items.filter { !$0.isDone }.count }

    /// 안 한 일을 위로, 체크한 일은 아래로 (완료로 거르지 않는 뷰에서 체크한 항목이 남는 경우).
    var displayItems: [TodoItem] {
        items.enumerated().sorted { a, b in
            a.element.isDone == b.element.isDone ? a.offset < b.offset : !a.element.isDone
        }.map(\.element)
    }

    static func placeholder(_ date: Date = .now) -> TodoEntry {
        TodoEntry(
            date: date, state: .ready, viewId: nil, viewName: String(localized: "To do"), isWritable: true,
            items: [
                TodoItem(id: "1", title: String(localized: "Buy toothpaste"), isDone: false),
                TodoItem(id: "2", title: String(localized: "Return the parcel"), isDone: false),
                TodoItem(id: "3", title: String(localized: "Call mom"), isDone: false),
                TodoItem(id: "4", title: String(localized: "Book a dentist appointment"), isDone: false),
            ],
            hasMore: false, isOffline: false, fetchedAt: date)
    }

    static func state(_ state: State, _ date: Date = .now) -> TodoEntry {
        TodoEntry(
            date: date, state: state, viewId: nil, viewName: "", isWritable: false, items: [], hasMore: false,
            isOffline: false, fetchedAt: nil)
    }
}

struct TodoTimelineProvider: AppIntentTimelineProvider {
    typealias Intent = SelectViewIntent
    typealias Entry = TodoEntry

    func placeholder(in context: Context) -> TodoEntry { .placeholder() }

    func snapshot(for configuration: SelectViewIntent, in context: Context) async -> TodoEntry {
        if context.isPreview, await !TodoServices.shared.isSignedIn { return .placeholder() }
        return await entry(for: configuration, network: !context.isPreview)
    }

    func timeline(for configuration: SelectViewIntent, in context: Context) async -> Timeline<TodoEntry> {
        let entry = await entry(for: configuration, network: true)
        return Timeline(entries: [entry], policy: .after(await nextRefresh(entry)))
    }

    /// 캐시로 먼저 그리고, 짧은 제한 시간 안에 data source 쿼리 1회로 덮는다 (PLAN 4.4).
    func entry(for configuration: SelectViewIntent, network: Bool) async -> TodoEntry {
        let services = TodoServices.shared
        guard await services.isSignedIn else { return .state(.signedOut) }
        let repository = services.repository
        var chosen = configuration.view?.id
        if chosen == nil { chosen = await repository.defaultViewId() }
        guard let viewId = chosen else { return .state(.needsView) }
        let cachedView = await repository.store.view(viewId)
        var snapshot = await repository.cachedItems(viewId)
        var isOffline = false
        if network {
            do {
                snapshot = try await withTimeout(.seconds(12)) { try await repository.fetchItems(viewId) }
            } catch NotionError.unauthorized {
                return .state(.reauth)
            } catch NotionError.notFound {
                return .state(.viewMissing)
            } catch {
                isOffline = true
            }
        }
        let view = await repository.store.view(viewId) ?? cachedView
        guard let snapshot else { return isOffline ? offlineEmpty(view) : .state(.viewMissing) }
        // 앱에서 정한 순서대로 (섹션 머리는 그리지 않고 순서만 따른다).
        return TodoEntry(
            date: .now, state: .ready, viewId: viewId, viewName: view?.name ?? configuration.view?.name ?? "",
            isWritable: view?.completion.isWritable ?? false, items: await repository.orderedItems(snapshot),
            hasMore: snapshot.hasMore, isOffline: isOffline, fetchedAt: snapshot.fetchedAt)
    }

    func offlineEmpty(_ view: ResolvedView?) -> TodoEntry {
        var entry = TodoEntry.state(.ready)
        entry.viewName = view?.name ?? ""
        entry.isOffline = true
        return entry
    }

    /// 20분 뒤. 날짜 조건("오늘")이 있는 뷰는 자정 직후로 당긴다.
    func nextRefresh(_ entry: TodoEntry) async -> Date {
        let regular = Date.now.addingTimeInterval(20 * 60)
        guard let viewId = entry.viewId, let view = await TodoServices.shared.repository.store.view(viewId),
            view.dependsOnDate,
            let midnight = Calendar.current.nextDate(
                after: .now, matching: DateComponents(hour: 0, minute: 1), matchingPolicy: .nextTime)
        else { return regular }
        return min(regular, midnight)
    }
}

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(_ duration: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
