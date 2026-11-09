import AppIntents
import DesignSystem
import SwiftUI
import TodoCore
import WidgetKit

// MARK: - 행

/// 위젯 한 줄. 체크 버튼은 `ToggleTodoIntent` — 잠금 상태에서도 동작한다.
struct WidgetTodoRow: View {
    var item: TodoItem
    var viewId: String?
    var isWritable: Bool
    var font: Font = .subheadline
    var lineLimit: Int = 1
    /// 글자 크기(Dynamic Type)에 맞춰 커진다.
    @ScaledMetric(relativeTo: .subheadline) private var diameter: CGFloat = 15

    var body: some View {
        if isWritable, let viewId, !item.isLocalOnly {
            Button(intent: ToggleTodoIntent(itemId: item.id, viewId: viewId, done: !item.isDone)) {
                label
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.accessibilityDescription)
            .accessibilityValue(item.accessibilityStatus)
            .accessibilityHint(Text(item.isDone ? "Marks as not done" : "Marks as done"))
        } else {
            label.accessibilityElement(children: .combine)
        }
    }

    var label: some View {
        let baselineOffset = diameter * 0.3
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if isWritable {
                    CheckCircle(isDone: item.isDone, isPending: item.isPending, diameter: diameter)
                } else {
                    Circle().frame(width: diameter / 3, height: diameter / 3).frame(width: diameter)
                }
            }
            .widgetAccentable()
            // 원의 중심을 글자 몸통 높이에 맞춘다.
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + baselineOffset }
            Text(item.title)
                .font(font)
                .strikethrough(item.isDone)
                .foregroundStyle(item.isDone ? .secondary : .primary)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .invalidatableContent(item.isPending)
        .contentShape(.rect)
    }
}

// MARK: - 목록 위젯

struct TodoListWidgetView: View {
    @Environment(\.widgetFamily) var family
    @Environment(\.showsWidgetContainerBackground) var showsBackground
    var entry: TodoEntry

    var body: some View {
        TodoListWidgetContent(entry: entry, family: family, showsBackground: showsBackground)
            .containerBackground(.background, for: .widget)
    }
}

/// 크기를 인자로 받아 스냅샷 테스트에서도 그릴 수 있게 한다 (`widgetFamily`는 환경에서 읽기 전용).
struct TodoListWidgetContent: View {
    var entry: TodoEntry
    var family: WidgetFamily
    var showsBackground: Bool = true
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        switch entry.state {
        case .ready: content
        default: StatusMessageView(entry: entry, family: family)
        }
    }

    @ViewBuilder var content: some View {
        switch family {
        #if os(iOS)
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
        #endif
        case .systemExtraLarge: list(capacity: 16, columns: 2)
        case .systemLarge: list(capacity: 9, columns: 1)
        case .systemMedium: list(capacity: 4, columns: 1)
        case .systemSmall: list(capacity: 3, columns: 1)
        default:
            #if compiler(>=6.3)
                if #available(iOS 27.0, macOS 27.0, *), family == .systemExtraLargePortrait {
                    list(capacity: 14, columns: 1)
                } else {
                    list(capacity: 4, columns: 1)
                }
            #else
                list(capacity: 4, columns: 1)
            #endif
        }
    }

    var isSmall: Bool { family == .systemSmall }
    /// StandBy처럼 배경 없이 크게 보이는 곳에서는 글자를 키운다.
    var rowFont: Font { showsBackground ? .subheadline : .title3 }

    /// 큰 글자에서는 같은 공간에 들어가는 줄이 줄어든다.
    func scaled(_ capacity: Int) -> Int {
        let factor: Double = switch typeSize {
        case ...DynamicTypeSize.large: 1
        case .xLarge, .xxLarge: 0.85
        case .xxxLarge: 0.75
        default: 0.5
        }
        return max(1, Int((Double(capacity) * factor).rounded(.down)))
    }

    func list(capacity: Int, columns: Int) -> some View {
        let items = Array(entry.displayItems.prefix(scaled(capacity)))
        let overflow = entry.items.count - items.count
        return VStack(alignment: .leading, spacing: isSmall ? 6 : 8) {
            header
            if items.isEmpty {
                Spacer(minLength: 0)
                emptyState
                Spacer(minLength: 0)
            } else if columns > 1 {
                let half = (items.count + 1) / 2
                HStack(alignment: .top, spacing: 16) {
                    rows(Array(items.prefix(half)))
                    rows(Array(items.dropFirst(half)))
                }
            } else {
                rows(items)
            }
            Spacer(minLength: 0)
            footer(overflow: overflow)
        }
    }

    func rows(_ items: [TodoItem]) -> some View {
        VStack(alignment: .leading, spacing: isSmall ? 5 : 7) {
            ForEach(items) { item in
                WidgetTodoRow(
                    item: item, viewId: entry.viewId, isWritable: entry.isWritable, font: rowFont,
                    lineLimit: family == .systemLarge || family == .systemExtraLarge ? 2 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(entry.viewName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(entry.hasMore ? "99+" : "\(entry.remaining)")
                .font(.memoCount(isSmall ? .title3 : .title2))
                .foregroundStyle(Color.memoAccent)
                .widgetAccentable()
                .accessibilityLabel(Text("\(entry.remaining) left"))
            if !isSmall {
                Link(destination: DeepLink.compose(viewId: entry.viewId)) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.memoAccent)
                        .widgetAccentable()
                }
                .accessibilityLabel(Text("Add memo"))
            }
        }
    }

    @ViewBuilder func footer(overflow: Int) -> some View {
        HStack(spacing: 4) {
            if overflow > 0 || entry.hasMore {
                Text(entry.hasMore ? "More in Notion" : "+\(overflow) more")
            }
            Spacer(minLength: 0)
            if entry.isOffline {
                Image(systemName: "icloud.slash")
                if let fetchedAt = entry.fetchedAt { Text(fetchedAt, style: .time) }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    var emptyState: some View {
        Label {
            Text("All done")
        } icon: {
            Image(systemName: "sparkles").widgetAccentable()
        }
        .font(isSmall ? .subheadline : .headline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    #if os(iOS)
        // 잠금화면: 단색으로 그려진다. 색 대신 모양으로 구분한다.
        var rectangular: some View {
            // 높이가 세 줄뿐이다: 3개 이하면 3줄, 넘치면 2줄 + "+N개 더".
            let all = entry.displayItems
            let items = Array(all.prefix(all.count > 3 ? 2 : 3))
            return VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    Label("All done", systemImage: "sparkles").font(.headline)
                } else {
                    ForEach(items) { item in
                        WidgetTodoRow(item: item, viewId: entry.viewId, isWritable: entry.isWritable, font: .body)
                    }
                    if all.count > items.count {
                        Text("+\(all.count - items.count) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        var inline: some View {
            // "할 일 3 · 치약 사기"
            if let first = entry.displayItems.first(where: { !$0.isDone }) {
                Text(verbatim: "\(entry.viewName) \(entry.remaining) · \(first.title)")
            } else {
                Text("All done")
            }
        }
    #endif
}

// MARK: - 상태 메시지

struct StatusMessageView: View {
    var entry: TodoEntry
    var family: WidgetFamily

    var body: some View {
        let (icon, message, url) = content
        Group {
            #if os(iOS)
                if family == .accessoryInline {
                    Text(message)
                } else if family == .accessoryCircular {
                    Image(systemName: icon)
                } else {
                    stack(icon, message)
                }
            #else
                stack(icon, message)
            #endif
        }
        .widgetURL(url)
    }

    func stack(_ icon: String, _ message: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.memoAccent).widgetAccentable()
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            if entry.state == .viewMissing, entry.viewId != nil {
                Button(intent: RefreshWidgetIntent(viewId: entry.viewId)) { Text("Try again") }
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var content: (String, LocalizedStringKey, URL) {
        switch entry.state {
        case .signedOut: ("person.crop.circle.badge.plus", "Sign in to Notion", DeepLink.onboarding)
        case .needsView: ("list.bullet.rectangle", "Choose a database in the app", DeepLink.onboarding)
        case .viewMissing: ("questionmark.folder", "View not found — edit the widget to choose again", DeepLink.compose())
        case .reauth: ("key", "Sign in again", DeepLink.onboarding)
        case .ready: ("checklist", "", DeepLink.compose())
        }
    }
}

// MARK: - 남은 개수 위젯

struct CountWidgetView: View {
    @Environment(\.widgetFamily) var family
    var entry: TodoEntry

    var body: some View {
        CountWidgetContent(entry: entry, family: family)
            .containerBackground(.background, for: .widget)
    }
}

struct CountWidgetContent: View {
    var entry: TodoEntry
    var family: WidgetFamily

    var body: some View {
        Group {
            if entry.state != .ready {
                StatusMessageView(entry: entry, family: family)
            } else {
                switch family {
                #if os(iOS)
                    case .accessoryCircular:
                        ZStack {
                            AccessoryWidgetBackground()
                            VStack(spacing: -2) {
                                Text("\(entry.remaining)").font(.memoCount(.title2))
                                Image(systemName: "checklist").font(.caption2)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(Text("\(entry.remaining) left"))
                #endif
                default:
                    VStack(alignment: .leading) {
                        Text(entry.viewName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(entry.hasMore ? "99+" : "\(entry.remaining)")
                            .font(.system(size: 56, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color.memoAccent)
                            .widgetAccentable()
                            .minimumScaleFactor(0.5)
                        Text("left").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
        }
        .widgetURL(DeepLink.compose(viewId: entry.viewId))
    }
}
