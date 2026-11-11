import Foundation
import Testing

@testable import TodoCore

/// 로컬 배치(순서·섹션) 규칙. Notion과 무관한 순수 계산이다.
@Suite struct LayoutTests {
    static func item(_ id: String, done: Bool = false) -> TodoItem { TodoItem(id: id, title: id, isDone: done) }
    let items = ["a", "b", "c", "d"].map { LayoutTests.item($0) }
    let work = LayoutSection(title: "일", tint: .blue)
    let home = LayoutSection(title: "집", tint: .green)

    func ids(_ rows: [LayoutRow]) -> [String] {
        rows.map { row in
            switch row.kind {
            case .item(let item): item.id
            case .header(let title, let count): "[\(title) \(count)]"
            }
        }
    }

    @Test func emptyLayoutKeepsNotionOrder() {
        let layout = ViewLayout()
        #expect(ids(layout.rows(for: items)) == ["a", "b", "c", "d"])
        #expect(layout.ordered(items) == items)
        #expect(layout.isEmpty)
    }

    @Test func newItemsComeFirstThenSavedOrderThenSections() {
        var section = work
        section.itemIds = ["d"]
        let layout = ViewLayout(itemIds: ["c", "a", "gone"], sections: [section, home])
        // b는 배치에 없는 새 항목, gone은 뷰에서 사라진 항목.
        let rows = layout.rows(for: items)
        #expect(ids(rows) == ["b", "c", "a", "[일 1]", "d", "[집 0]"])
        #expect(rows.map(\.sectionId) == [nil, nil, nil, work.id, work.id, home.id])
        #expect(rows.map(\.tint) == [nil, nil, nil, .blue, .blue, .green])
        // 빈 섹션은 머리 줄이 곧 마지막 줄이다 (카드 한 줄).
        #expect(rows.map(\.isLastInSection) == [false, false, false, false, true, true])
        #expect(layout.ordered(items).map(\.id) == ["b", "c", "a", "d"])
    }

    @Test func rowIdentityFollowsItsBackground() {
        // 섹션 밖 항목은 항목 ID 그대로. 섹션에 들어가거나, 카드의 끝 줄이 바뀌거나, 색이 바뀌면 다른 줄이 된다.
        var section = work
        section.itemIds = ["c"]
        var layout = ViewLayout(sections: [section])
        let before = layout.rows(for: items)
        #expect(before.map(\.id).prefix(3) == ["a", "b", "d"])
        let headerId = before[3].id
        let lastId = before[4].id
        #expect(lastId != "c")

        layout.sections[0].itemIds = ["c", "d"]
        var after = layout.rows(for: items)
        #expect(after[2].id == headerId, "항목이 늘어도 머리는 같은 줄이다")
        #expect(after[3].id != lastId, "끝 줄이 아니게 되면 배경 모양이 달라진다")
        #expect(after[4].item?.id == "d" && after[4].id != "d")

        layout.sections[0].tint = .pink
        after = layout.rows(for: items)
        #expect(after[2].id != headerId)

        layout.sections[0].itemIds = []
        #expect(layout.rows(for: items).last?.id != after[2].id, "빈 섹션의 머리는 카드 한 줄이라 모양이 다르다")
        #expect(Set(layout.rows(for: items).map(\.id)).count == 5, "줄 ID는 겹치지 않는다")
    }

    @Test func doneItemsSinkWithinTheirOwnGroup() {
        var section = work
        section.itemIds = ["c", "d"]
        let layout = ViewLayout(itemIds: ["a", "b"], sections: [section])
        let mixed = [Self.item("a", done: true), Self.item("b"), Self.item("c", done: true), Self.item("d")]
        #expect(ids(layout.rows(for: mixed, doneLast: true)) == ["b", "a", "[일 2]", "d", "c"])
        #expect(ids(layout.rows(for: mixed)) == ["a", "b", "[일 2]", "c", "d"])
    }

    @Test func firstDragRecordsWhatIsOnScreen() {
        var layout = ViewLayout()
        // d를 맨 위로 끈다.
        layout.move(rows: layout.rows(for: items), fromOffsets: [3], toOffset: 0)
        #expect(layout.itemIds == ["d", "a", "b", "c"])
        // a를 맨 아래로 끈다.
        layout.move(rows: layout.rows(for: items), fromOffsets: [1], toOffset: 4)
        #expect(layout.itemIds == ["d", "b", "c", "a"])
    }

    @Test func droppingBelowAHeaderPutsItemIntoThatSection() {
        var layout = ViewLayout(sections: [work, home])
        // 줄: a b c d [일] [집]. a를 [일] 머리 바로 아래에 놓는다.
        layout.move(rows: layout.rows(for: items), fromOffsets: [0], toOffset: 5)
        #expect(layout.sections[0].itemIds == ["a"])
        // 줄: b c d [일] a [집]. b를 빈 섹션 머리 아래(맨 끝)에 놓는다.
        var rows = layout.rows(for: items)
        #expect(ids(rows) == ["b", "c", "d", "[일 1]", "a", "[집 0]"])
        layout.move(rows: rows, fromOffsets: [0], toOffset: 6)
        #expect(layout.sections[1].itemIds == ["b"])
        // 줄: c d [일] a [집] b. c를 a 아래(= [집] 머리 위)에 놓으면 [일]의 끝이다.
        rows = layout.rows(for: items)
        layout.move(rows: rows, fromOffsets: [0], toOffset: 4)
        #expect(layout.sections[0].itemIds == ["a", "c"])
        // 섹션 안 항목을 맨 위로 끌면 섹션 밖으로 나온다.
        rows = layout.rows(for: items)
        #expect(ids(rows) == ["d", "[일 2]", "a", "c", "[집 1]", "b"])
        layout.move(rows: rows, fromOffsets: [5], toOffset: 0)
        #expect(layout.itemIds == ["b", "d"])
        #expect(layout.sections[1].itemIds.isEmpty)
        // 첫 섹션 머리 바로 위에 놓으면 섹션 밖 맨 아래다.
        rows = layout.rows(for: items)
        #expect(ids(rows) == ["b", "d", "[일 2]", "a", "c", "[집 0]"])
        layout.move(rows: rows, fromOffsets: [4], toOffset: 2)
        #expect(layout.itemIds == ["b", "d", "c"])
        #expect(layout.sections[0].itemIds == ["a"])
    }

    @Test func everythingInSectionsCanStillComeOut() {
        // 섹션 밖에 아무것도 없어도 첫 머리 위에 놓으면 섹션 밖으로 나온다.
        var section = work
        section.itemIds = ["a", "b", "c", "d"]
        var layout = ViewLayout(sections: [section])
        let rows = layout.rows(for: items)
        #expect(ids(rows) == ["[일 4]", "a", "b", "c", "d"])
        layout.move(rows: rows, fromOffsets: [2], toOffset: 0)
        #expect(layout.itemIds == ["b"])
        #expect(layout.sections[0].itemIds == ["a", "c", "d"])
    }

    @Test func draggingAHeaderMovesTheWholeSection() {
        var first = work
        first.itemIds = ["b"]
        var second = home
        second.itemIds = ["c", "d"]
        var layout = ViewLayout(itemIds: ["a"], sections: [first, second])
        // 줄: a [일] b [집] c d
        var rows = layout.rows(for: items)
        #expect(ids(rows) == ["a", "[일 1]", "b", "[집 2]", "c", "d"])

        // [집] 머리를 [일] 머리 위에 놓으면 [집]이 담긴 항목과 함께 앞으로 온다.
        layout.move(rows: rows, fromOffsets: [3], toOffset: 1)
        #expect(layout.sections.map(\.id) == [home.id, work.id])
        rows = layout.rows(for: items)
        #expect(ids(rows) == ["a", "[집 2]", "c", "d", "[일 1]", "b"])

        // 섹션 밖 항목 사이(맨 위)에 놓아도 섹션은 섹션 밖 항목 아래에 남는다: 이미 첫 섹션이라 그대로다.
        var before = layout
        layout.move(rows: rows, fromOffsets: [1], toOffset: 0)
        #expect(layout == before)

        // 다른 섹션 안에 놓으면 그 섹션 머리를 지난 것으로 본다 → [집]이 [일] 뒤로 간다.
        layout.move(rows: rows, fromOffsets: [1], toOffset: 6)
        #expect(layout.sections.map(\.id) == [work.id, home.id])

        // 자기 섹션 안이나 앞 섹션 안에 놓으면 그대로다.
        rows = layout.rows(for: items)
        #expect(ids(rows) == ["a", "[일 1]", "b", "[집 2]", "c", "d"])
        before = layout
        layout.move(rows: rows, fromOffsets: [3], toOffset: 5)
        #expect(layout == before)
        layout.move(rows: rows, fromOffsets: [3], toOffset: 2)
        #expect(layout == before)
        layout.move(rows: rows, fromOffsets: [1], toOffset: 3)
        #expect(layout == before)
        #expect(layout.itemIds == ["a"], "머리를 끌어도 항목은 그대로다")
    }

    @Test func rowsOutOfRangeDoNotMove() {
        var layout = ViewLayout(itemIds: ["a", "b", "c", "d"], sections: [work])
        let before = layout
        layout.move(rows: layout.rows(for: items), fromOffsets: [9], toOffset: 0)
        #expect(layout == before)
    }

    @Test func hiddenItemsKeepTheirPlaceAcrossMoves() {
        // b는 방금 체크해서 화면에서 빠졌다. 그사이 다른 항목을 옮겨도 b의 자리는 남는다.
        var layout = ViewLayout(itemIds: ["a", "b", "c", "d"])
        let visible = items.filter { $0.id != "b" }
        layout.move(rows: layout.rows(for: visible), fromOffsets: [2], toOffset: 0)  // d를 맨 위로
        #expect(layout.itemIds == ["d", "a", "b", "c"])
    }

    @Test func moveToSectionAndBack() {
        var layout = ViewLayout(sections: [work])
        layout.move(itemId: "c", toSection: work.id, visibleIds: items.map(\.id))
        layout.move(itemId: "a", toSection: work.id, visibleIds: items.map(\.id))
        #expect(layout.sections[0].itemIds == ["c", "a"])
        #expect(layout.itemIds == ["b", "d"])
        #expect(layout.sectionId(of: "a") == work.id)
        layout.move(itemId: "a", toSection: nil, visibleIds: items.map(\.id))
        #expect(layout.itemIds == ["a", "b", "d"])
        #expect(layout.sectionId(of: "a") == nil)
    }

    @Test func sectionEditing() {
        var layout = ViewLayout(itemIds: ["a"], sections: [work, home])
        #expect(layout.nextTint == .yellow)
        layout.updateSection(work.id, title: "회사", tint: .pink)
        #expect(layout.sections[0].title == "회사")
        #expect(layout.sections[0].tint == .pink)
        layout.moveSection(work.id, by: 1)
        #expect(layout.sections.map(\.id) == [home.id, work.id])
        layout.moveSection(work.id, by: 1)  // 이미 맨 아래
        #expect(layout.sections.map(\.id) == [home.id, work.id])

        layout.move(itemId: "b", toSection: work.id, visibleIds: ["a", "b"])
        layout.removeSection(work.id)
        #expect(layout.sections.map(\.id) == [home.id])
        #expect(layout.itemIds == ["a", "b"], "섹션을 지우면 담겨 있던 항목은 섹션 밖 맨 아래로 간다")
    }

    @Test func resetReturnsToNotionOrderButKeepsSections() {
        var section = work
        section.itemIds = ["d", "gone", "b"]
        var layout = ViewLayout(itemIds: ["c", "a"], sections: [section])
        layout.resetOrder(notionOrder: items.map(\.id))
        #expect(layout.itemIds.isEmpty)
        #expect(layout.sections[0].itemIds == ["b", "d", "gone"])
        #expect(ids(layout.rows(for: items)) == ["a", "c", "[일 2]", "b", "d"])
        // 이미 Notion 순서면 다시 해도 달라지지 않는다 ("되돌리기" 버튼을 끄는 기준).
        let once = layout
        layout.resetOrder(notionOrder: items.map(\.id))
        #expect(layout == once)
    }

    @Test func replaceAndPrune() {
        var section = work
        section.itemIds = ["local-1"]
        var layout = ViewLayout(itemIds: ["a", "local-2"], sections: [section])
        layout.replace(itemId: "local-1", with: "p1")
        layout.replace(itemId: "local-2", with: "p2")
        #expect(layout.itemIds == ["a", "p2"])
        #expect(layout.sections[0].itemIds == ["p1"])

        // 사라진 항목이 조금이면 남겨 두고(체크 → 되돌리기), 많이 쌓이면 한꺼번에 치운다.
        layout.prune(keeping: ["a"], tolerance: 2)
        #expect(layout.itemIds == ["a", "p2"])
        layout.prune(keeping: ["a"], tolerance: 1)
        #expect(layout.itemIds == ["a"])
        #expect(layout.sections[0].itemIds.isEmpty)
    }

    @Test func layoutRoundTripsThroughStore() throws {
        let store = SharedStore(root: FileManager.default.temporaryDirectory.appending(path: "nt-layout-\(UUID().uuidString)"))
        defer { store.wipe() }
        #expect(store.layout("v1") == nil)
        var section = work
        section.itemIds = ["b"]
        let layout = ViewLayout(itemIds: ["a"], sections: [section])
        try store.save(layout: layout, viewId: "v1")
        #expect(store.layout("v1") == layout)
        store.removeLayout("v1")
        #expect(store.layout("v1") == nil)
    }
}
