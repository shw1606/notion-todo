import Foundation
import Testing

@testable import TodoCore

/// 잠금 화면 카드에 넘기는 내용. Notion과 무관한 순수 계산이다.
@Suite struct LockScreenCardTests {
    static func item(_ id: String, done: Bool = false, title: String? = nil) -> TodoItem {
        TodoItem(id: id, title: title ?? id, isDone: done)
    }

    static func state(_ items: [TodoItem], hasMore: Bool = false) -> LockScreenCardState {
        LockScreenCardState(
            viewId: "view", viewName: "할 일", isWritable: true, items: items, hasMore: hasMore,
            fetchedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func showsUndoneFirstUpToTheLimit() {
        let items = [
            Self.item("a"), Self.item("b", done: true), Self.item("c"), Self.item("d"), Self.item("e"),
            Self.item("f"), Self.item("g"),
        ]
        let state = Self.state(items)
        // 체크한 b는 아래로 가서 다섯 줄 밖으로 밀린다.
        #expect(state.rows.map(\.id) == ["a", "c", "d", "e", "f"])
        #expect(state.remaining == 6)
        #expect(state.rows.count == LockScreenCardState.rowLimit)
    }

    @Test func checkedItemsStayBelowWhileThereIsRoom() {
        let state = Self.state([Self.item("a", done: true), Self.item("b"), Self.item("c")])
        #expect(state.rows.map(\.id) == ["b", "c", "a"])
        #expect(state.rows.map(\.isDone) == [false, false, true])
        #expect(state.remaining == 2)
    }

    @Test func localOnlyItemsCannotBeToggled() {
        let state = Self.state([Self.item(TodoItem.localPrefix + "1"), Self.item("a")])
        #expect(state.rows.map(\.canToggle) == [false, true])
    }

    @Test func togglingShowsTheResultBeforeNotionAnswers() {
        let state = Self.state([Self.item("a"), Self.item("b"), Self.item("c")])
        let checked = state.toggling("a", done: true)
        #expect(checked.rows.map(\.id) == ["b", "c", "a"])
        #expect(checked.remaining == 2)
        // 다시 누르면 되돌아간다. 원래 자리는 다음 조회 때 맞춰진다.
        let undone = checked.toggling("a", done: false)
        #expect(undone.rows.map(\.isDone) == [false, false, false])
        #expect(undone.remaining == 3)
        // 카드에 없는 항목, 이미 그 상태인 항목은 그대로.
        #expect(state.toggling("zzz", done: true) == state)
        #expect(state.toggling("a", done: false) == state)
    }

    @Test func nextCardsSkipTheNight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Seoul"))
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        func starts(_ now: Date) -> [Date] {
            LockScreenCardSchedule.reservedStarts(after: now, interval: 12 * 3600, count: 2, calendar: calendar)
        }
        // 낮에 띄우면 12시간 뒤는 한밤 → 아침 8시로, 그 다음은 거기서 12시간 뒤.
        #expect(starts(date(11, 14, 36)) == [date(12, 8), date(12, 20)])
        // 아침에 띄우면 그대로 12시간씩.
        #expect(starts(date(11, 9)) == [date(11, 21), date(12, 9)])
        // 밤 10시 정각부터 아침 8시 직전까지가 밤이다.
        #expect(starts(date(11, 10)) == [date(12, 8), date(12, 20)])
        #expect(starts(date(11, 19, 59)) == [date(12, 7, 59).addingTimeInterval(60), date(12, 20)])
        #expect(starts(date(11, 20)) == [date(12, 8), date(12, 20)])
        // 시험할 때처럼 밤을 따지지 않으면 간격 그대로.
        let plain = LockScreenCardSchedule.reservedStarts(
            after: date(11, 14), interval: 45, count: 2, quietHours: nil, calendar: calendar)
        #expect(plain == [date(11, 14).addingTimeInterval(45), date(11, 14).addingTimeInterval(90)])
    }

    @Test func longTitlesFitInOneUpdate() throws {
        // 한 번에 넘길 수 있는 내용은 4KB까지다. 한글·이모지로 가득 찬 긴 제목 다섯 줄도 그 안에 들어가야 한다.
        let long = String(repeating: "가나다라마바사👨‍👩‍👧‍👦", count: 80)
        let items = (0..<8).map { Self.item("0123456789abcdef0123456789abcdef-\($0)", title: long) }
        let state = LockScreenCardState(
            viewId: "0123456789abcdef0123456789abcdef", viewName: long, isWritable: true, items: items, hasMore: true,
            fetchedAt: .now)
        let encoded = try JSONEncoder().encode(state)
        #expect(encoded.count < 4000, "\(encoded.count)바이트")
        for row in state.rows {
            #expect(row.title.utf8.count <= LockScreenCardState.titleByteLimit)
            #expect(row.title.hasSuffix("…"))
        }
        // 짧은 제목은 건드리지 않는다.
        #expect(Self.state([Self.item("a", title: "치약 사기")]).rows[0].title == "치약 사기")
    }
}
