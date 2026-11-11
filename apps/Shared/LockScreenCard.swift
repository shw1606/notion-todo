import Foundation

#if os(iOS)
    import ActivityKit
    import AppIntents
    import BackgroundTasks
    import OSLog
    import TodoCore
    import WidgetKit

    // 앱·위젯 확장 양쪽에 컴파일된다. 카드를 그리는 쪽은 위젯 확장(`TodoCardActivity`), 켜고 고치는 쪽은 앱 프로세스다.

    /// 잠금 화면 카드(실시간 현황). 잠금 화면 위젯은 작은 칸 하나가 가장 큰 크기라, 가로 전체를 쓰는 큰 목록은 이것으로 띄운다
    /// (DECISIONS 2026-11-11).
    struct TodoCardAttributes: ActivityAttributes {
        typealias ContentState = LockScreenCardState
    }

    /// 카드를 켜고, 내용을 고치고, 끈다. 앱 프로세스에서만 한다 — 위젯 확장은 실시간 현황을 건드릴 수 없다.
    ///
    /// iOS는 실시간 현황을 8시간 뒤에 끝내고 길어야 12시간 뒤에 잠금 화면에서 치운다. 그래서 앱을 열 때 새 카드로 바꿔
    /// 시계를 다시 돌리고, 그러지 않는 동안을 위해 다음 카드를 예약해 둔다.
    enum LockScreenCard {
        enum Key {
            static let isOn = "showsLockScreenCard"
            static let viewId = "lockScreenCardViewId"
            static let startedAt = "lockScreenCardStartedAt"
            /// 예약해 둔 카드가 뜰 시각 (카드 ID → 시각). 예약한 카드에서는 시각을 읽을 수 없어서 적어 둔다.
            static let reservedStarts = "lockScreenCardReservations"
        }

        /// 앱을 앞에 둔 동안에는 바꿔도 보이지 않으니 자주 바꾼다.
        static var renewInApp: TimeInterval { debugSeconds("NT_DEV_CARD_RENEW_IN_APP") ?? 30 * 60 }
        /// 이보다 오래된 내용이면 카드에 받아 온 시각을 적는다.
        static let staleAfter: TimeInterval = 30 * 60
        /// 다음 카드를 예약해 두는 간격. iOS는 카드를 8시간 뒤에 끝내고(끝난 카드는 잠금 화면에 남아 있고 눌러도 된다)
        /// 길어야 12시간 뒤에 치운다. 먼저 카드가 치워질 때 다음 카드가 뜨게 한다 — 더 일찍 띄우면 두 장이 한 묶음으로
        /// 겹쳐지고, 겹친 카드는 첫 탭이 체크가 아니라 묶음 펼치기가 된다.
        static var reserveInterval: TimeInterval { debugSeconds("NT_DEV_CARD_INTERVAL") ?? 12 * 3600 }
        /// 미리 예약해 두는 카드 수. 앱을 열지도 체크하지도 않아도 하루 반쯤 이어진다.
        static let reservedCards = 2

        /// 개발 빌드에서 시간을 줄여 시험한다 (초).
        private static func debugSeconds(_ name: String) -> TimeInterval? {
            #if DEBUG
                ProcessInfo.processInfo.environment[name].flatMap(TimeInterval.init)
            #else
                nil
            #endif
        }

        /// 앱과 위젯 확장이 같이 읽는다 (위젯의 체크가 어느 인텐트로 갈지). `UserDefaults`는 어느 스레드에서 써도 된다.
        nonisolated(unsafe) static let defaults: UserDefaults =
            AppConfiguration.fromBundle().appGroupId.flatMap(UserDefaults.init(suiteName:)) ?? .standard

        static var isOn: Bool { defaults.bool(forKey: Key.isOn) }

        /// 이 기기에서 실시간 현황을 쓸 수 있는가 (설정 ▸ 앱에서 끌 수 있다).
        static var isAllowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

        private static let isAppProcess = Bundle.main.bundleURL.pathExtension != "appex"
        static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "notiontodo", category: "card")

        /// 카드가 보여 줄 뷰. 고른 뷰가 목록에서 빠졌으면 할 일을 보여 주는 뷰로 돌아간다.
        static func viewId() async -> String? {
            let catalog = await TodoServices.shared.repository.cachedCatalog()
            if let chosen = defaults.string(forKey: Key.viewId), catalog.contains(where: { $0.id == chosen }) {
                return chosen
            }
            return catalog.preferredDefault?.id
        }

        // MARK: 맞추기

        @MainActor private static var tail: Task<Void, Never>?

        /// 새 카드를 띄울지.
        enum Start {
            /// 떠 있는 카드의 내용만 고친다.
            case no
            /// 떠 있는 카드가 없으면 띄운다 (카드·위젯의 체크, 설정에서 켤 때).
            case ifMissing
            /// 없거나 그보다 오래 떠 있었으면 새 카드로 바꾼다 (앱이 앞에 올 때).
            case ifOlderThan(TimeInterval)
        }

        /// 카드를 지금 설정·캐시에 맞춘다. 부른 순서대로 하나씩 한다.
        /// - Parameters:
        ///   - start: 새 카드를 띄울지. 띄우는 것은 앱이 앞에 있을 때와 `LiveActivityIntent` 안에서만 된다.
        ///   - fetch: 카드의 뷰를 Notion에서 다시 받아 온 뒤에 맞춘다.
        @MainActor
        static func sync(start: Start = .no, fetch: Bool = false) async {
            guard isAppProcess else { return }
            let previous = tail
            let task = Task {
                await previous?.value
                await syncOnce(start: start, fetch: fetch)
            }
            tail = task
            await task.value
        }

        private static func syncOnce(start policy: Start, fetch: Bool) async {
            let all = Activity<TodoCardAttributes>.activities
            guard let state = await desiredState(fetch: fetch) else {
                for activity in all { await activity.end(nil, dismissalPolicy: .immediate) }
                reservedStarts = [:]
                if !all.isEmpty { log.notice("카드를 치움 (\(all.count)장)") }
                return
            }
            let shown = all.filter { $0.activityState == .active || $0.activityState == .stale }
            let pending = all.filter { $0.activityState == .pending }
            let isDue =
                switch policy {
                case .no: false
                case .ifMissing: shown.isEmpty
                case .ifOlderThan(let age):
                    shown.isEmpty || Date.now.timeIntervalSince1970 - defaults.double(forKey: Key.startedAt) > age
                }
            // 새 카드를 먼저 띄우고 옛 카드를 치운다. 띄우지 못하면(앱이 뒤에 있다) 있던 카드를 그대로 둔다.
            if isDue, start(state) {
                // 예약은 옛 카드를 치운 뒤에 한다: 앱 하나가 가질 수 있는 실시간 현황은 예약한 것까지 다섯 장쯤이라,
                // 옛 카드를 둔 채로는 새 예약이 거절된다 (`targetMaximumExceeded`, iPhone에서 확인).
                for old in all where old.activityState != .pending { await old.end(nil, dismissalPolicy: .immediate) }
                let known = reservedStarts
                let reserved = reserveNext(state)
                // 옛 예약은 새로 다 예약했으면 지운다. 다 하지 못했으면 — 앱이 뒤에 있을 때는 인텐트 한 번에 카드 한 장만
                // 띄울 수 있다 — 새 카드와 겹치지 않을 만큼 뒤에 뜨는 것은 남겨서 이어지게 한다.
                let clear = (reserved.last ?? .now).addingTimeInterval(reserveInterval).timeIntervalSince1970
                for old in pending {
                    if reserved.count < reservedCards, let start = known[old.id], start >= clear { continue }
                    await old.end(nil, dismissalPolicy: .immediate)
                }
                log.notice("카드를 띄움 (예약 \(reserved.count)장)")
                forgetGoneReservations()
                scheduleRefresh()
                return
            }
            // 내용만 고친다. 치울 것을 먼저 치우고 예약을 다시 한다.
            let newest = shown.max { $0.content.relevanceScore < $1.content.relevanceScore }
            var updated = 0
            for activity in all where activity.activityState != .pending {
                if activity.id != newest?.id {
                    // 예약한 카드가 떴으면 그 전 카드는 치운다. iOS가 끝낸 카드는 잠금 화면에 몇 시간 더 남는데,
                    // 떠 있는 카드가 있으면 치우고 없으면 둔다 (누르면 새 카드가 뜬다).
                    if newest != nil { await activity.end(nil, dismissalPolicy: .immediate) }
                } else if activity.content.state != state {
                    await activity.update(content(state, start: nil, keeping: activity))
                    updated += 1
                }
            }
            // 예약해 둔 카드는 내용을 고칠 수 없다 (고쳐도 예약할 때의 내용으로 뜬다). 같은 시각으로 다시 예약하고 먼저 것을
            // 지운다. 다시 예약하지 못하면(앱이 뒤에 있다) 먼저 것을 둔다 — 옛 내용이라도 카드는 이어진다. 먼저 뜰 것부터 한다.
            var starts = reservedStarts
            for activity in pending.sorted(by: { starts[$0.id] ?? .infinity < starts[$1.id] ?? .infinity }) {
                var reserved = activity.content.state
                reserved.fetchedAt = state.fetchedAt
                guard reserved != state, let start = starts[activity.id].map(Date.init(timeIntervalSince1970:)),
                    start.timeIntervalSinceNow > 5, let id = reserve(state, start: start)
                else { continue }
                starts[id] = start.timeIntervalSince1970
                starts[activity.id] = nil
                await activity.end(nil, dismissalPolicy: .immediate)
                updated += 1
            }
            reservedStarts = starts
            forgetGoneReservations()
            if updated > 0 { log.notice("카드 내용을 고침 (\(updated)장, \(state.rows.count)줄, 남은 일 \(state.remaining))") }
        }

        /// 지금 카드 한 장을 띄운다.
        private static func start(_ state: LockScreenCardState) -> Bool {
            do {
                _ = try Activity.request(
                    attributes: TodoCardAttributes(), content: content(state, start: .now), pushType: nil)
            } catch {
                // 앱이 앞에 있지 않으면 `visibility`로 거절된다 (`LiveActivityIntent` 안에서는 뒤에서도 한 장은 된다).
                log.error("카드를 띄우지 못함: \(String(describing: error), privacy: .public)")
                return false
            }
            defaults.set(Date.now.timeIntervalSince1970, forKey: Key.startedAt)
            return true
        }

        /// 방금 띄운 카드가 치워질 때마다 이어서 뜰 카드를 예약한다. 예약한 시각들을 돌려준다.
        private static func reserveNext(_ state: LockScreenCardState) -> [Date] {
            // 시험할 때(간격을 초로 줄였을 때)는 밤을 따지지 않는다.
            let quiet = debugSeconds("NT_DEV_CARD_INTERVAL") == nil ? LockScreenCardSchedule.quietHours : nil
            let dates = LockScreenCardSchedule.reservedStarts(
                after: .now, interval: reserveInterval, count: reservedCards, quietHours: quiet)
            var starts = reservedStarts
            var reserved: [Date] = []
            for date in dates {
                guard let id = reserve(state, start: date) else { break }
                starts[id] = date.timeIntervalSince1970
                reserved.append(date)
            }
            reservedStarts = starts
            return reserved
        }

        /// `start`에 뜰 카드를 예약한다. 예약한 카드의 ID를 돌려준다.
        private static func reserve(_ state: LockScreenCardState, start: Date) -> String? {
            do {
                return try Activity.request(
                    attributes: TodoCardAttributes(), content: content(state, start: start), pushType: nil,
                    style: .standard, alertConfiguration: quietAlert, start: start
                ).id
            } catch {
                log.error("다음 카드를 예약하지 못함: \(String(describing: error), privacy: .public)")
                return nil
            }
        }

        private static var reservedStarts: [String: Double] {
            get { defaults.dictionary(forKey: Key.reservedStarts) as? [String: Double] ?? [:] }
            set { defaults.set(newValue, forKey: Key.reservedStarts) }
        }

        /// 떴거나 지운 예약은 적어 둔 시각에서 뺀다.
        private static func forgetGoneReservations() {
            let pending = Set(
                Activity<TodoCardAttributes>.activities.filter { $0.activityState == .pending }.map(\.id))
            reservedStarts = reservedStarts.filter { pending.contains($0.key) }
        }

        /// 예약한 카드가 뜰 때의 알림. 시스템이 꼭 받는 값이다. 소리는 내지 않는다 (소리 없는 파일).
        private static var quietAlert: AlertConfiguration {
            AlertConfiguration(
                title: "Todo Widget", body: "Your memos are still on the Lock Screen.", sound: .named("card-silence.caf"))
        }

        /// 나중에 뜨는 카드일수록 순서 값을 크게 준다 (날 수로 센 뜨는 시각). 같은 앱의 카드가 겹치면 한 묶음으로 쌓이는데,
        /// 순서 값이 큰 카드가 위에 온다. 내용만 고칠 때는 그 카드의 값을 그대로 둔다.
        private static func content(
            _ state: LockScreenCardState, start: Date?, keeping activity: Activity<TodoCardAttributes>? = nil
        ) -> ActivityContent<LockScreenCardState> {
            let order = start.map { $0.timeIntervalSince(orderEpoch) / 86_400 } ?? activity?.content.relevanceScore ?? 0
            return ActivityContent(
                state: state, staleDate: state.fetchedAt.addingTimeInterval(staleAfter), relevanceScore: order)
        }

        private static let orderEpoch = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01

        /// 지금 카드에 올릴 내용. 꺼져 있거나 보여 줄 것이 없으면 nil → 카드를 치운다.
        private static func desiredState(fetch: Bool) async -> LockScreenCardState? {
            guard isOn, isAllowed else { return nil }
            let services = TodoServices.shared
            guard await services.isSignedIn, let viewId = await viewId() else { return nil }
            let repository = services.repository
            var snapshot = await repository.cachedItems(viewId)
            if fetch || snapshot == nil {
                // 실패하면(오프라인 등) 캐시에 있는 것으로 그린다.
                if let fresh = try? await repository.fetchItems(viewId) { snapshot = fresh }
            }
            guard let snapshot, let view = await repository.store.view(viewId) else { return nil }
            return LockScreenCardState(
                viewId: viewId, viewName: view.name, isWritable: view.completion.isWritable,
                items: await repository.orderedItems(snapshot), hasMore: snapshot.hasMore, fetchedAt: snapshot.fetchedAt)
        }

        // MARK: 뒤에서 새로 받기

        /// 카드는 스스로 Notion을 조회하지 못한다. 앱을 열지 않는 동안에는 iOS가 틈틈이 앱을 뒤에서 깨워 줄 때 새로 받아
        /// 카드에 올린다 (언제, 얼마나 자주 깨울지는 iOS가 정한다).
        static let refreshTaskId = (Bundle.main.bundleIdentifier ?? "notiontodo") + ".card-refresh"

        static func scheduleRefresh() {
            guard isAppProcess, isOn else { return }
            // 시뮬레이터에는 BGTaskScheduler가 없다.
            #if !targetEnvironment(simulator)
                let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
                request.earliestBeginDate = Date.now.addingTimeInterval(20 * 60)
                do {
                    try BGTaskScheduler.shared.submit(request)
                } catch {
                    log.error("새로 받기를 예약하지 못함: \(String(describing: error), privacy: .public)")
                }
            #endif
        }

        /// iOS가 뒤에서 깨웠다.
        @MainActor
        static func backgroundRefresh() async {
            log.notice("뒤에서 새로 받음")
            scheduleRefresh()
            await sync(fetch: true)
            WidgetCenter.shared.reloadAllTimelines()
        }

        /// 체크를 누른 자리에서 바로 보이게 한다. Notion에 보내는 것은 그 다음이다.
        static func showToggle(itemId: String, done: Bool) async {
            guard isAppProcess else { return }
            for activity in Activity<TodoCardAttributes>.activities
            where activity.activityState == .active || activity.activityState == .stale {
                let next = activity.content.state.toggling(itemId, done: done)
                if next != activity.content.state {
                    await activity.update(
                        ActivityContent(
                            state: next, staleDate: activity.content.staleDate,
                            relevanceScore: activity.content.relevanceScore))
                }
            }
        }
    }

    // MARK: - 체크

    /// 잠금 화면 카드의 체크 버튼. 카드를 켜 둔 동안에는 위젯의 체크도 이것으로 보낸다.
    ///
    /// `ToggleTodoIntent`와 하는 일은 같고 도는 곳이 다르다: `LiveActivityIntent`는 위젯 확장이 아니라 앱 프로세스에서
    /// 돌아서, 체크한 뒤에 카드를 고치고 필요하면 새로 띄울 수 있다.
    struct ToggleCardTodoIntent: LiveActivityIntent {
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
            LockScreenCard.log.notice("체크 인텐트 (\(ProcessInfo.processInfo.processName, privacy: .public))")
            await LockScreenCard.showToggle(itemId: itemId, done: done)
            // 실패해도 대기열에 남아 다음 기회에 보내진다. 카드와 위젯은 캐시의 낙관적 상태로 다시 그린다.
            try? await TodoServices.shared.repository.setDone(viewId: viewId, itemId: itemId, done: done)
            // 떠 있는 카드가 없으면(iOS가 끝냈다) 새로 띄운다. 끝난 카드는 고칠 수 없어서, 그러지 않으면 체크한 것이 보이지 않는다.
            await LockScreenCard.sync(start: .ifMissing)
            WidgetCenter.shared.reloadAllTimelines()
            // 앱이 열려 있으면 그 화면도 캐시에서 다시 읽는다.
            NotificationCenter.default.post(name: .notionTodoItemsChanged, object: nil)
            return .result()
        }
    }
#endif

extension Notification.Name {
    /// 항목이 바뀌었다 → 같은 캐시를 읽는 다른 창·떠 있는 메모가 다시 읽는다. 보낸 쪽은 `object`로 자기를 알린다.
    static let notionTodoItemsChanged = Notification.Name("NotionTodoItemsChanged")
}
