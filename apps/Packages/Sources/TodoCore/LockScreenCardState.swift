import Foundation

/// 잠금 화면 카드(iPhone의 실시간 현황)가 보여 주는 내용. 카드는 앱이 넘겨준 이 값만으로 그려진다 —
/// 위젯과 달리 스스로 Notion을 조회하지 못한다.
public struct LockScreenCardState: Codable, Hashable, Sendable {
    public struct Row: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var isDone: Bool
        /// 아직 Notion에 만들어지지 않은 항목은 체크할 수 없다 (위젯과 같다).
        public var canToggle: Bool

        public init(id: String, title: String, isDone: Bool, canToggle: Bool) {
            self.id = id
            self.title = title
            self.isDone = isDone
            self.canToggle = canToggle
        }
    }

    public var viewId: String
    public var viewName: String
    public var isWritable: Bool
    /// 안 한 일 먼저, 최대 `rowLimit`줄.
    public var rows: [Row]
    /// 안 한 일의 수 (카드에 올리지 못한 것 포함).
    public var remaining: Int
    /// Notion에 더 있다 (한 번에 받는 양을 넘었다).
    public var hasMore: Bool
    /// 이 내용을 Notion에서 받아 온 때.
    public var fetchedAt: Date

    /// 카드 높이(160pt)에 들어가는 줄 수.
    public static let rowLimit = 5
    /// 한 번에 넘길 수 있는 내용이 4KB까지다. 한 줄에 보이는 것은 30자쯤이라 넉넉히 잘라 둔다.
    public static let titleByteLimit = 360

    public init(
        viewId: String, viewName: String, isWritable: Bool, rows: [Row], remaining: Int, hasMore: Bool, fetchedAt: Date
    ) {
        self.viewId = viewId
        self.viewName = viewName
        self.isWritable = isWritable
        self.rows = rows
        self.remaining = remaining
        self.hasMore = hasMore
        self.fetchedAt = fetchedAt
    }

    /// `items`는 사용자가 정한 순서대로 (`TodoRepository.orderedItems`).
    public init(viewId: String, viewName: String, isWritable: Bool, items: [TodoItem], hasMore: Bool, fetchedAt: Date) {
        self.init(
            viewId: viewId, viewName: Self.clipped(viewName, bytes: 120), isWritable: isWritable,
            rows: Self.rows(items), remaining: items.filter { !$0.isDone }.count, hasMore: hasMore, fetchedAt: fetchedAt)
    }

    /// 안 한 일을 위로, 체크한 일은 아래로 (방금 체크한 항목이 다음 조회까지 남아 있는 동안).
    static func rows(_ items: [TodoItem]) -> [Row] {
        let sorted = items.enumerated().sorted { a, b in
            a.element.isDone == b.element.isDone ? a.offset < b.offset : !a.element.isDone
        }
        return sorted.prefix(rowLimit).map {
            Row(
                id: $0.element.id, title: clipped($0.element.title, bytes: titleByteLimit), isDone: $0.element.isDone,
                canToggle: !$0.element.isLocalOnly)
        }
    }

    /// 체크를 누른 직후, Notion에 보내기 전에 먼저 보여 줄 모습. 카드에 없는 항목이면 그대로다.
    public func toggling(_ itemId: String, done: Bool) -> LockScreenCardState {
        guard let index = rows.firstIndex(where: { $0.id == itemId }), rows[index].isDone != done else { return self }
        var next = self
        next.rows[index].isDone = done
        next.remaining = max(0, remaining + (done ? -1 : 1))
        let sorted = next.rows.enumerated().sorted { a, b in
            a.element.isDone == b.element.isDone ? a.offset < b.offset : !a.element.isDone
        }
        next.rows = sorted.map(\.element)
        return next
    }

    /// 글자 중간을 자르지 않고 UTF-8 `bytes` 안으로 줄인다.
    static func clipped(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > bytes - 3 { break }
            result.append(character)
            used += size
        }
        return result + "…"
    }
}

/// 잠금 화면 카드를 이어 붙이는 시간표. iOS는 실시간 현황을 8시간 뒤에 끝내고 길어야 12시간 뒤에 잠금 화면에서 치우므로,
/// 앱이 돌지 않는 동안을 위해 다음 카드가 뜰 시각을 미리 정해 예약해 둔다.
public enum LockScreenCardSchedule {
    /// 예약한 카드는 뜰 때 화면을 켠다. 이 시간대(22시~다음 날 8시)에 뜰 차례면 아침으로 미룬다.
    public static let quietHours = 22..<32

    /// `now`에 카드를 띄웠을 때 이어서 뜰 카드들의 시각. 밤에 걸려 미뤄진 카드가 있으면 그 뒤 카드는 미뤄진 시각부터 센다.
    public static func reservedStarts(
        after now: Date, interval: TimeInterval, count: Int, quietHours: Range<Int>? = quietHours,
        calendar: Calendar = .current
    ) -> [Date] {
        var starts: [Date] = []
        var next = now
        for _ in 0..<count {
            next = afterQuietHours(next.addingTimeInterval(interval), quietHours: quietHours, calendar: calendar)
            starts.append(next)
        }
        return starts
    }

    static func afterQuietHours(_ date: Date, quietHours: Range<Int>?, calendar: Calendar) -> Date {
        guard let quietHours else { return date }
        let hour = calendar.component(.hour, from: date)
        let wake = quietHours.upperBound % 24
        guard quietHours.contains(hour) || quietHours.contains(hour + 24) else { return date }
        return calendar.nextDate(after: date, matching: DateComponents(hour: wake, minute: 0), matchingPolicy: .nextTime)
            ?? date
    }
}
