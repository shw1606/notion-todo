import Foundation

/// 섹션 배경에 연하게 까는 색.
public enum SectionTint: String, Codable, CaseIterable, Sendable {
    case yellow, blue, green, pink, purple, gray
}

/// 사용자가 이 기기에서 만든 섹션: 레이블·색·담긴 항목 순서.
public struct LayoutSection: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var tint: SectionTint
    public var itemIds: [String]

    public init(id: UUID = UUID(), title: String, tint: SectionTint, itemIds: [String] = []) {
        self.id = id
        self.title = title
        self.tint = tint
        self.itemIds = itemIds
    }
}

/// 뷰 하나의 로컬 배치: 항목 순서와 섹션. Notion에는 보내지 않고 이 기기(App Group)에만 둔다 (DECISIONS 2026-11-11).
///
/// 목록은 섹션 밖 항목 → 섹션 순으로 그린다. 배치에 없는 항목(새로 생긴 것)은 섹션 밖 맨 위에 온다.
public struct ViewLayout: Codable, Hashable, Sendable {
    /// 섹션 밖 항목의 순서. 비어 있으면 Notion 뷰의 정렬을 그대로 따른다.
    public var itemIds: [String]
    public var sections: [LayoutSection]

    public init(itemIds: [String] = [], sections: [LayoutSection] = []) {
        self.itemIds = itemIds
        self.sections = sections
    }

    public var isEmpty: Bool { itemIds.isEmpty && sections.isEmpty }

    var allIds: Set<String> { Set(itemIds).union(sections.flatMap(\.itemIds)) }

    public func sectionId(of itemId: String) -> UUID? {
        sections.first { $0.itemIds.contains(itemId) }?.id
    }
}

/// 목록의 한 줄: 항목이나 섹션 머리.
///
/// 줄은 모두 끌어 옮길 수 있어야 한다. SwiftUI `List`는 옮길 수 없게 막은 줄(`moveDisabled`)의 자리에는
/// 놓지도 못하게 해서, 머리를 막으면 섹션 맨 위나 섹션 바로 위에 놓을 수 없다. 그래서 빈 섹션에도 따로 안내 줄을
/// 두지 않고 머리 줄 하나로 그린다.
public struct LayoutRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case item(TodoItem)
        /// `count`가 0이면 빈 섹션: 머리 줄이 끌어다 놓을 자리를 겸한다.
        case header(title: String, count: Int)
    }

    /// 줄의 정체성. 배경이 달라지면(들어 있는 섹션, 섹션 색, 카드의 끝 줄인지) 다른 줄로 친다:
    /// `List`는 이미 그린 줄의 배경·구분선을 다시 읽지 않아서, 같은 줄로 두면 섹션에 넣은 직후 색이 칠해지지 않는다.
    public var id: String
    public var kind: Kind
    /// 섹션 밖이면 nil.
    public var sectionId: UUID?
    public var tint: SectionTint?
    /// 섹션의 마지막 줄 (배경 아래쪽 모서리를 둥글린다).
    public var isLastInSection: Bool

    public var item: TodoItem? {
        if case .item(let item) = kind { return item }
        return nil
    }

    public var isHeader: Bool {
        if case .header = kind { return true }
        return false
    }
}

// MARK: - 그리기

extension ViewLayout {
    /// 목록에 그릴 줄. `doneLast`: 완료로 거르지 않는 뷰에서는 체크한 항목을 묶음 안에서 아래로 내린다.
    public func rows(for items: [TodoItem], doneLast: Bool = false) -> [LayoutRow] {
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = allIds
        func sorted(_ bucket: [TodoItem]) -> [TodoItem] {
            doneLast ? bucket.filter { !$0.isDone } + bucket.filter(\.isDone) : bucket
        }

        let loose = sorted(items.filter { !known.contains($0.id) } + itemIds.compactMap { byId[$0] })
        var rows = loose.map { LayoutRow(id: $0.id, kind: .item($0), sectionId: nil, tint: nil, isLastInSection: false) }
        for section in sections {
            let members = sorted(section.itemIds.compactMap { byId[$0] })
            rows.append(
                LayoutRow(
                    id: Self.headerRowId(section, isEmpty: members.isEmpty),
                    kind: .header(title: section.title, count: members.count),
                    sectionId: section.id, tint: section.tint, isLastInSection: members.isEmpty))
            for (index, item) in members.enumerated() {
                let isLast = index == members.count - 1
                rows.append(
                    LayoutRow(
                        id: "\(item.id)|\(section.id.uuidString)|\(section.tint.rawValue)|\(isLast ? "last" : "mid")",
                        kind: .item(item), sectionId: section.id, tint: section.tint, isLastInSection: isLast))
            }
        }
        return rows
    }

    static func headerRowId(_ section: LayoutSection, isEmpty: Bool) -> String {
        "section-\(section.id.uuidString)|\(section.tint.rawValue)|\(isEmpty ? "empty" : "open")"
    }

    /// 섹션 머리 없이 항목만, 보이는 순서대로 (위젯·메뉴 막대).
    public func ordered(_ items: [TodoItem]) -> [TodoItem] {
        isEmpty ? items : rows(for: items).compactMap(\.item)
    }
}

// MARK: - 바꾸기

extension ViewLayout {
    /// 화면에 보이는데 배치에 없는 항목을 보이는 순서대로 섹션 밖 맨 위에 적어 둔다.
    /// 옮기기 전에 불러서, 지금 보이는 순서가 기준이 되게 한다.
    mutating func adopt(_ visibleIds: [String]) {
        let known = allIds
        itemIds.insert(contentsOf: visibleIds.filter { !known.contains($0) }, at: 0)
    }

    mutating func remove(_ ids: Set<String>) {
        itemIds.removeAll(where: ids.contains)
        for index in sections.indices { sections[index].itemIds.removeAll(where: ids.contains) }
    }

    /// 목록에서 줄을 끌어 옮긴 것을 반영한다 (`onMove`). `rows`는 옮기기 전 화면의 줄이다.
    ///
    /// 항목은 놓은 자리 바로 윗줄이 기준이다: 섹션 머리 아래에 놓으면 그 섹션의 맨 위, 맨 위에 놓으면 섹션 밖 맨 위.
    /// 섹션 머리를 끌면 섹션이 담긴 항목과 함께 옮겨 간다: 놓은 자리보다 위에 있는 다른 섹션 수가 새 순번이다
    /// (섹션은 다른 섹션 안이나 섹션 밖 항목 사이로 들어가지 않는다).
    public mutating func move(rows: [LayoutRow], fromOffsets source: IndexSet, toOffset destination: Int) {
        let picked = source.filter { $0 < rows.count }.map { rows[$0] }
        if let sectionId = picked.first(where: \.isHeader)?.sectionId {
            let above = rows.prefix(max(0, min(destination, rows.count))).filter { $0.isHeader && $0.sectionId != sectionId }
            moveSection(sectionId, to: above.count)
            return
        }
        let moving = picked.compactMap { $0.item?.id }
        guard !moving.isEmpty else { return }
        adopt(rows.compactMap { $0.item?.id })

        var anchorIndex = min(destination, rows.count) - 1
        while anchorIndex >= 0, source.contains(anchorIndex) { anchorIndex -= 1 }
        let anchor = anchorIndex >= 0 ? rows[anchorIndex] : nil
        remove(Set(moving))

        guard let anchor else {
            itemIds.insert(contentsOf: moving, at: 0)
            return
        }
        let anchorItemId = anchor.item?.id
        if let sectionId = anchor.sectionId, let index = sections.firstIndex(where: { $0.id == sectionId }) {
            let position = anchorItemId.flatMap { sections[index].itemIds.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            sections[index].itemIds.insert(contentsOf: moving, at: position)
        } else {
            let position = anchorItemId.flatMap { itemIds.firstIndex(of: $0) }.map { $0 + 1 } ?? itemIds.count
            itemIds.insert(contentsOf: moving, at: position)
        }
    }

    /// 항목을 섹션 맨 아래로 옮긴다. `sectionId`가 nil이면 섹션 밖 맨 위로. `visibleIds`는 지금 보이는 항목 순서.
    public mutating func move(itemId: String, toSection sectionId: UUID?, visibleIds: [String]) {
        adopt(visibleIds)
        remove([itemId])
        if let sectionId, let index = sections.firstIndex(where: { $0.id == sectionId }) {
            sections[index].itemIds.append(itemId)
        } else {
            itemIds.insert(itemId, at: 0)
        }
    }

    /// 새 섹션에 줄 색: 아직 안 쓴 색부터.
    public var nextTint: SectionTint {
        let used = Set(sections.map(\.tint))
        return SectionTint.allCases.first { !used.contains($0) }
            ?? SectionTint.allCases[sections.count % SectionTint.allCases.count]
    }

    public mutating func updateSection(_ id: UUID, title: String? = nil, tint: SectionTint? = nil) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        if let title { sections[index].title = title }
        if let tint { sections[index].tint = tint }
    }

    /// 섹션을 담긴 항목과 함께 위(-1)·아래(+1)로 옮긴다.
    public mutating func moveSection(_ id: UUID, by offset: Int) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        moveSection(id, to: index + offset)
    }

    /// 섹션을 `target`번째 자리로 옮긴다 (범위를 벗어나면 맨 위·맨 아래).
    public mutating func moveSection(_ id: UUID, to target: Int) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(target, 0), sections.count - 1)
        guard target != index else { return }
        sections.insert(sections.remove(at: index), at: target)
    }

    /// 섹션만 없앤다. 담겨 있던 항목은 섹션 밖 맨 아래로 간다.
    public mutating func removeSection(_ id: UUID) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        itemIds.append(contentsOf: sections.remove(at: index).itemIds)
    }

    /// 사용자가 정한 순서를 버리고 Notion 뷰의 정렬로 돌아간다. 섹션과 어느 섹션에 담겼는지는 그대로 둔다.
    public mutating func resetOrder(notionOrder: [String]) {
        let rank = Dictionary(notionOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        itemIds = []
        for index in sections.indices {
            sections[index].itemIds = sections[index].itemIds.enumerated().sorted { a, b in
                // 지금 뷰에 없는 항목은 원래 순서대로 뒤에 둔다.
                (rank[a.element] ?? Int.max, a.offset) < (rank[b.element] ?? Int.max, b.offset)
            }.map(\.element)
        }
    }

    /// 오프라인으로 만든 항목이 Notion에 올라가 ID가 바뀌면 제자리를 지키게 한다.
    public mutating func replace(itemId old: String, with new: String) {
        if let index = itemIds.firstIndex(of: old) { itemIds[index] = new }
        for section in sections.indices {
            if let index = sections[section].itemIds.firstIndex(of: old) { sections[section].itemIds[index] = new }
        }
    }

    /// 뷰에서 사라진 항목 ID를 치운다. 체크했다가 되돌리면 제자리로 돌아오도록 `tolerance`개까지는 남겨 둔다.
    public mutating func prune(keeping ids: Set<String>, tolerance: Int = 50) {
        let stale = allIds.subtracting(ids)
        guard stale.count > tolerance else { return }
        remove(stale)
    }
}
