import AppIntents
import SwiftUI
import WidgetKit

@main
struct NotionTodoWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodoListWidget()
        CountWidget()
        AddMemoControl()
    }
}

enum WidgetKind {
    static let list = "TodoListWidget"
    static let count = "CountWidget"
    static let addControl = "AddMemoControl"
}

struct TodoListWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.list, intent: SelectViewIntent.self, provider: TodoTimelineProvider()) {
            TodoListWidgetView(entry: $0)
        }
        .configurationDisplayName("Memos")
        .description("Your Notion view, always in sight. Tap a circle to check it off.")
        .supportedFamilies(Self.families)
    }

    static var families: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        // 세로형 초대형은 iOS·macOS 27 SDK(Xcode 27, Swift 6.3+)에만 있다.
        #if compiler(>=6.3)
            if #available(iOS 27.0, macOS 27.0, *) { families.append(.systemExtraLargePortrait) }
        #endif
        #if os(iOS)
            families += [.accessoryRectangular, .accessoryInline]
        #endif
        return families
    }
}

struct CountWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.count, intent: SelectViewIntent.self, provider: TodoTimelineProvider()) {
            CountWidgetView(entry: $0)
        }
        .configurationDisplayName("Memos Left")
        .description("How many memos are left in a view.")
        .supportedFamilies(Self.families)
    }

    static var families: [WidgetFamily] {
        #if os(iOS)
            [.systemSmall, .accessoryCircular]
        #else
            [.systemSmall]
        #endif
    }
}

/// 제어 센터·잠금화면·동작 버튼·Mac 메뉴 막대에서 한 번에 기록 화면 열기 (PLAN 4.6).
struct AddMemoControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKind.addControl) {
            ControlWidgetButton(action: OpenURLIntent(DeepLink.compose())) {
                Label("Add Memo", systemImage: "square.and.pencil")
            }
        }
        .displayName("Add Memo")
        .description("Opens Notion Todo ready to write.")
    }
}

#Preview("Medium", as: .systemMedium) {
    TodoListWidget()
} timeline: {
    TodoEntry.placeholder()
    TodoEntry.state(.signedOut)
}

#Preview("Small", as: .systemSmall) {
    TodoListWidget()
} timeline: {
    TodoEntry.placeholder()
}

#if os(iOS)
    #Preview("Lock Screen", as: .accessoryRectangular) {
        TodoListWidget()
    } timeline: {
        TodoEntry.placeholder()
    }
#endif
