import Foundation
import NotionKit

/// 뷰 정의 + data source 스키마 → `ResolvedView`. 사용자에게 속성 매핑을 묻지 않기 위한 핵심 규칙이 여기 있다.
public enum ViewResolver {
    public static func resolve(view: NotionView, schema: DataSource, now: Date = .now) -> ResolvedView {
        let filter = mergedFilter(view)
        let conditions = requiredConditions(filter)
        let properties = Array(schema.properties.values)
        let (completion, showsDone, fromFilter) = inferCompletion(conditions: conditions, properties: properties)
        let titleId = properties.first { $0.type == "title" }?.id ?? "title"
        return ResolvedView(
            id: view.id,
            name: view.name,
            databaseId: view.databaseId ?? schema.databaseId,
            dataSourceId: view.dataSourceId ?? schema.id,
            databaseTitle: schema.title.plainText,
            url: view.url,
            filter: filter,
            sorts: view.sorts,
            titlePropertyId: titleId,
            completion: completion,
            datePropertyId: inferDateProperty(view: view, conditions: conditions, properties: properties),
            showsDone: showsDone,
            filtersByCompletion: fromFilter,
            createRules: createRules(conditions: conditions, properties: properties),
            resolvedAt: now)
    }

    // MARK: 필터 합치기

    /// Notion UI에서 건 필터는 `quick_filters`에, API로 만든 필터는 `filter`에 저장된다. 둘 다 AND로 합친다.
    public static func mergedFilter(_ view: NotionView) -> JSONValue? {
        var parts: [JSONValue] = []
        if let filter = view.filter, !filter.isNull, filter.objectValue?.isEmpty != true { parts.append(filter) }
        for (key, condition) in (view.quickFilters ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard var object = condition.objectValue, hasCriteria(object) else { continue }
            object["property"] = .string(key)
            parts.append(.object(object))
        }
        switch parts.count {
        case 0: return nil
        case 1: return parts[0]
        default:
            // 합친 결과가 Notion의 중첩 한도(2단계)를 넘지 않도록, 첫 필터가 AND면 그 안에 이어 붙인다.
            if let and = parts[0]["and"]?.arrayValue {
                return ["and": .array(and + parts.dropFirst())]
            }
            return ["and": .array(parts)]
        }
    }

    /// 조건 없이 필터 바에 속성만 올려 둔 quick filter(`{}` 또는 `{"select": {}}`)는 건너뛴다.
    static func hasCriteria(_ object: [String: JSONValue]) -> Bool {
        object.contains { key, value in key != "property" && value.objectValue?.isEmpty == false }
    }

    // MARK: 조건 추출

    struct Condition: Hashable {
        var property: String
        var type: String
        var op: String
        var value: JSONValue
    }

    /// 반드시 성립해야 하는 조건(최상위 AND 사슬)만 뽑는다. OR 안쪽은 필수가 아니므로 무시한다.
    static func requiredConditions(_ filter: JSONValue?) -> [Condition] {
        guard let object = filter?.objectValue else { return [] }
        if let and = object["and"]?.arrayValue { return and.flatMap(requiredConditions) }
        if object["or"] != nil { return [] }
        guard let property = object["property"]?.stringValue else { return [] }
        for (type, body) in object where type != "property" {
            guard let ops = body.objectValue, let (op, value) = ops.first else { continue }
            return [Condition(property: property, type: type, op: op, value: value)]
        }
        return []
    }

    static func schema(for key: String, in properties: [PropertySchema]) -> PropertySchema? {
        let wanted = NotionID.property(key)
        return properties.first { NotionID.property($0.id) == wanted } ?? properties.first { $0.name == key }
    }

    // MARK: 완료 추론

    static func inferCompletion(conditions: [Condition], properties: [PropertySchema])
        -> (CompletionStrategy, showsDone: Bool, fromFilter: Bool)
    {
        for condition in conditions {
            guard let prop = schema(for: condition.property, in: properties), prop.type == condition.type else {
                continue
            }
            switch prop.type {
            case "checkbox":
                guard let value = condition.value.boolValue else { continue }
                switch condition.op {
                case "equals": return (.checkbox(propertyId: prop.id), value, true)
                case "does_not_equal": return (.checkbox(propertyId: prop.id), !value, true)
                default: continue
                }
            case "status":
                guard let status = prop.status, let strategy = statusStrategy(prop, status),
                    let option = statusOption(condition.value, status)
                else { continue }
                let isComplete = status.optionIds(inGroup: "Complete").contains(option.id)
                switch condition.op {
                case "equals": return (strategy, isComplete, true)
                case "does_not_equal" where isComplete: return (strategy, false, true)
                default: continue
                }
            default:
                continue
            }
        }
        // 뷰 필터로 못 정하면, DB에 하나뿐인 status → checkbox 순으로 쓴다.
        let statuses = properties.filter { $0.type == "status" }
        if statuses.count == 1, let status = statuses[0].status, let strategy = statusStrategy(statuses[0], status) {
            return (strategy, false, false)
        }
        let checkboxes = properties.filter { $0.type == "checkbox" }
        if checkboxes.count == 1 { return (.checkbox(propertyId: checkboxes[0].id), false, false) }
        let reason: ReadOnlyReason = statuses.isEmpty && checkboxes.isEmpty ? .noCompletionProperty : .ambiguous
        return (.readOnly(reason), false, false)
    }

    static func statusStrategy(_ prop: PropertySchema, _ status: StatusSchema) -> CompletionStrategy? {
        let complete = status.optionIds(inGroup: "Complete")
        guard let done = complete.first else { return nil }
        let undo = status.optionIds(inGroup: "To-do").first
            ?? status.optionIds(inGroup: "In progress").first
            ?? status.options.first { !complete.contains($0.id) }?.id
        guard let undo else { return nil }
        return .status(propertyId: prop.id, doneOptionId: done, undoOptionId: undo, completeOptionIds: complete)
    }

    /// 필터 값은 옵션 이름(UI·API 모두)으로 오지만, ID일 수도 있어 둘 다 받는다.
    static func statusOption(_ value: JSONValue, _ status: StatusSchema) -> StatusSchema.Option? {
        guard let text = value.stringValue else { return nil }
        return status.option(named: text) ?? status.option(id: text)
    }

    // MARK: 날짜

    static func inferDateProperty(view: NotionView, conditions: [Condition], properties: [PropertySchema])
        -> String?
    {
        let sortKeys = (view.sorts?.arrayValue ?? []).compactMap { $0["property"]?.stringValue }
        for key in sortKeys + conditions.map(\.property) {
            if let prop = schema(for: key, in: properties), prop.type == "date" { return prop.id }
        }
        let dates = properties.filter { $0.type == "date" }
        return dates.count == 1 ? dates[0].id : nil
    }

    // MARK: 새 항목 기본값

    static func createRules(conditions: [Condition], properties: [PropertySchema]) -> [CreateRule] {
        conditions.compactMap { condition in
            guard let prop = schema(for: condition.property, in: properties), prop.type == condition.type else {
                return nil
            }
            switch (prop.type, condition.op) {
            case ("checkbox", "equals"):
                return condition.value.boolValue.map { .checkbox(propertyId: prop.id, value: $0) }
            case ("checkbox", "does_not_equal"):
                return condition.value.boolValue.map { .checkbox(propertyId: prop.id, value: !$0) }
            case ("status", "equals"):
                guard let status = prop.status, let option = statusOption(condition.value, status) else { return nil }
                return .statusName(propertyId: prop.id, name: option.name)
            case ("select", "equals"):
                return condition.value.stringValue.map { .selectName(propertyId: prop.id, name: $0) }
            case ("multi_select", "contains"):
                return condition.value.stringValue.map { .multiSelectName(propertyId: prop.id, name: $0) }
            case ("people", "contains") where condition.value.stringValue == "me":
                return .peopleMe(propertyId: prop.id)
            case ("date", "equals"):
                return condition.value.stringValue.map { .date(propertyId: prop.id, value: $0) }
            default:
                return nil
            }
        }
    }
}

// MARK: - 페이지 → 항목

extension ResolvedView {
    func value(_ page: Page, propertyId: String) -> PropertyValue? {
        let wanted = NotionID.property(propertyId)
        return page.properties.values.first { NotionID.property($0.id) == wanted }
    }

    public func item(from page: Page) -> TodoItem {
        let title = value(page, propertyId: titlePropertyId)?.title?.plainText ?? page.titleText
        return TodoItem(
            id: page.id,
            title: title,
            isDone: isDone(page),
            due: datePropertyId.flatMap { value(page, propertyId: $0)?.date?.start },
            url: page.url,
            createdTime: page.createdTime)
    }

    func isDone(_ page: Page) -> Bool {
        switch completion {
        case .checkbox(let id):
            return value(page, propertyId: id)?.checkbox ?? false
        case .status(let id, _, _, let complete):
            guard let option = value(page, propertyId: id)?.status else { return false }
            return complete.contains(option.id)
        case .readOnly:
            return false
        }
    }

    /// 완료 상태를 `done`으로 바꾸는 PATCH 본문.
    public func completionPatch(done: Bool) -> JSONValue? {
        switch completion {
        case .checkbox(let id):
            return [id: ["checkbox": .bool(done)]]
        case .status(let id, let doneOption, let undoOption, _):
            return [id: ["status": ["id": .string(done ? doneOption : undoOption)]]]
        case .readOnly:
            return nil
        }
    }

    public func titlePatch(_ text: String) -> JSONValue {
        [titlePropertyId: ["title": [["text": ["content": .string(text)]]]]]
    }

    /// 새 항목 속성: 제목 + 뷰 조건을 만족하는 기본값. "완료함" 뷰에서 추가하면 완료 상태로 만들어진다.
    public func createProperties(title: String, ownerUserId: String?, now: Date = .now, calendar: Calendar = .current)
        -> JSONValue
    {
        var properties = titlePatch(title).objectValue ?? [:]
        for rule in createRules {
            switch rule {
            case .checkbox(let id, let value):
                properties[id] = ["checkbox": .bool(value)]
            case .statusName(let id, let name):
                properties[id] = ["status": ["name": .string(name)]]
            case .selectName(let id, let name):
                properties[id] = ["select": ["name": .string(name)]]
            case .multiSelectName(let id, let name):
                properties[id] = ["multi_select": [["name": .string(name)]]]
            case .peopleMe(let id):
                if let ownerUserId { properties[id] = ["people": [["id": .string(ownerUserId)]]] }
            case .date(let id, let value):
                if let date = Self.resolveDate(value, now: now, calendar: calendar) {
                    properties[id] = ["date": ["start": .string(date)]]
                }
            }
        }
        return .object(properties)
    }

    /// 날짜 필터 값: 상대값("today" 등)은 지금 기준으로, 날짜 문자열은 그대로.
    static func resolveDate(_ value: String, now: Date, calendar: Calendar) -> String? {
        let offset: Int? = switch value {
        case "today": 0
        case "tomorrow": 1
        case "yesterday": -1
        default: nil
        }
        if let offset, let day = calendar.date(byAdding: .day, value: offset, to: now) {
            return DayFormat.string(day, calendar: calendar)
        }
        return value.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil ? value : nil
    }

    /// 날짜 조건이 있는 뷰는 자정에 결과가 바뀐다 → 위젯이 자정 직후 갱신을 예약한다.
    public var dependsOnDate: Bool {
        guard let filter else { return false }
        return Self.containsDateCondition(filter)
    }

    static func containsDateCondition(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let object):
            if object["date"] != nil || object["timestamp"] != nil { return true }
            return object.values.contains(where: containsDateCondition)
        case .array(let array):
            return array.contains(where: containsDateCondition)
        default:
            return false
        }
    }
}

public enum DayFormat {
    public static func string(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `2026-11-10` 또는 ISO 8601 시각을 Date로.
    public static func date(_ text: String, calendar: Calendar = .current) -> Date? {
        if text.count == 10 {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        return try? Date(text, strategy: .iso8601)
    }
}
