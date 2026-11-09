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

    var body: some View {
        if isWritable, let viewId, !item.isLocalOnly {
            Button(intent: ToggleTodoIntent(itemId: item.id, viewId: viewId, done: !item.isDone)) {
                label
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.accessibilityDescription)
            .accessibilityHint(Text(item.isDone ? "Marks as not done" : "Marks as done"))
        } else {
            label.accessibilityElement(children: .combine)
        }
    }

    var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if isWritable {
                    CheckCircle(isDone: item.isDone, isPending: item.isPending, diameter: 15)
                } else {
                    Circle().frame(width: 5, height: 5).padding(.horizontal, 5)
                }
            }
            .widgetAccentable()
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
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
        Group {
            switch entry.state {
            case .ready: content
            default: StatusMessageView(entry: entry)
            }
        }
        .containerBackground(.background, for: .widget)
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
            if #available(iOS 27.0, macOS 27.0, *), family == .systemExtraLargePortrait {
                list(capacity: 14, columns: 1)
            } else {
                list(capacity: 4, columns: 1)
            }
        }
    }

    var isSmall: Bool { family == .systemSmall }
    /// StandBy처럼 배경 없이 크게 보이는 곳에서는 글자를 키운다.
    var rowFont: Font { showsBackground ? .subheadline : .title3 }

    func list(capacity: Int, columns: Int) -> some View {
        let items = Array(entry.displayItems.prefix(capacity))
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
            let items = Array(entry.displayItems.prefix(3))
            return VStack(alignment: .leading, spacing: 1) {
                if items.isEmpty {
                    Label("All done", systemImage: "sparkles").font(.headline)
                } else {
                    ForEach(items) { item in
                        WidgetTodoRow(item: item, viewId: entry.viewId, isWritable: entry.isWritable, font: .body)
                    }
                    if entry.items.count > items.count {
                        Text("+\(entry.items.count - items.count) more").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        var inline: some View {
            if let first = entry.displayItems.first(where: { !$0.isDone }) {
                Text("\(entry.remaining) · \(first.title)")
            } else {
                Text("All done")
            }
        }
    #endif
}

// MARK: - 상태 메시지

struct StatusMessageView: View {
    @Environment(\.widgetFamily) var family
    var entry: TodoEntry

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
        Group {
            if entry.state != .ready {
                StatusMessageView(entry: entry)
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
        .containerBackground(.background, for: .widget)
    }
}
