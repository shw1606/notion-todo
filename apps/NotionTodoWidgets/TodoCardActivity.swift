#if os(iOS)
    import ActivityKit
    import AppIntents
    import DesignSystem
    import SwiftUI
    import TodoCore
    import WidgetKit

    /// 잠금 화면 카드: 가로 전체를 쓰는 메모 목록. 실시간 현황이라 Dynamic Island에도 남은 개수가 보인다.
    struct TodoCardActivity: Widget {
        var body: some WidgetConfiguration {
            ActivityConfiguration(for: TodoCardAttributes.self) { context in
                TodoCardView(state: context.state, isStale: context.isStale)
                    // 시스템이 까는 어두운 바탕을 걷어 내고, 카드가 직접 투명한 리퀴드 글라스를 두른다.
                    .activityBackgroundTint(.clear)
                    .activitySystemActionForegroundColor(.primary)
                    .widgetURL(DeepLink.view(context.state.viewId))
            } dynamicIsland: { context in
                let state = context.state
                return DynamicIsland {
                    DynamicIslandExpandedRegion(.leading) {
                        Text(state.viewName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 4)
                    }
                    DynamicIslandExpandedRegion(.trailing) {
                        TodoCardCount(state: state, style: .title3)
                            .padding(.trailing, 4)
                    }
                    DynamicIslandExpandedRegion(.bottom) {
                        // 펼친 섬은 낮다 → 세 줄까지.
                        TodoCardRows(state: state, limit: 3)
                    }
                } compactLeading: {
                    Image(systemName: "checklist").foregroundStyle(Color.memoAccent)
                } compactTrailing: {
                    TodoCardCount(state: state, style: .body)
                } minimal: {
                    TodoCardCount(state: state, style: .body)
                }
                .widgetURL(DeepLink.view(state.viewId))
                .keylineTint(Color.memoAccent)
            }
        }
    }

    /// 잠금 화면에 보이는 모습. 시스템이 주는 높이는 160pt까지이고 넘치면 잘린다.
    struct TodoCardView: View {
        var state: LockScreenCardState
        var isStale = false
        /// 글자 크기(Dynamic Type)를 키우면 줄이 높아지고, 그만큼 줄 수가 준다.
        @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = TodoCardRow.height
        @ScaledMetric(relativeTo: .caption) private var headerHeight: CGFloat = 22

        static let maxHeight: CGFloat = 160
        static let verticalPadding: CGFloat = 10
        static let spacing: CGFloat = 4

        var rowLimit: Int {
            let room = Self.maxHeight - Self.verticalPadding * 2 - headerHeight - Self.spacing
            return min(LockScreenCardState.rowLimit, max(1, Int(room / rowHeight)))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: Self.spacing) {
                header.frame(height: headerHeight)
                TodoCardRows(state: state, limit: rowLimit)
            }
            // 맑은 유리 위에서 밝은 배경 화면에도 글자가 묻히지 않게 옅은 그림자를 깐다.
            .shadow(color: .black.opacity(0.28), radius: 2, y: 0.5)
            .padding(.horizontal, 16)
            .padding(.vertical, Self.verticalPadding)
            .background { CardGlass() }
        }

        var header: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(state.viewName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.7))
                    .lineLimit(1)
                if isStale {
                    // 카드는 스스로 새로 받아 오지 못한다. 오래된 내용이면 언제 것인지 적는다 (누르면 앱이 열려 새로 받는다).
                    Label {
                        Text(state.fetchedAt, style: .time)
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Last updated \(state.fetchedAt, style: .time)"))
                }
                Spacer(minLength: 4)
                TodoCardCount(state: state, style: .title3)
                Link(destination: DeepLink.compose(viewId: state.viewId)) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.memoAccent)
                }
                .accessibilityLabel(Text("Add memo"))
            }
        }
    }

    /// 뒤가 비치는 맑은 유리판 위에 가장자리 빛과 위쪽 반사광을 얹는다.
    struct CardGlass: View {
        private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

        var body: some View {
            ZStack {
                Color.clear.glassEffect(.clear, in: shape)
                // 위쪽에서 비스듬히 떨어지는 빛 (반짝임).
                shape.fill(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.04), .clear, .white.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                // 유리 모서리의 얇은 빛 테두리: 왼쪽 위와 오른쪽 아래가 밝다.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.85), .white.opacity(0.12), .white.opacity(0.12), .white.opacity(0.55)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    struct TodoCardCount: View {
        var state: LockScreenCardState
        var style: Font.TextStyle

        var body: some View {
            Text(state.hasMore ? "99+" : "\(state.remaining)")
                .font(.memoCount(style))
                .foregroundStyle(Color.memoAccent)
                .accessibilityLabel(Text("\(state.remaining) left"))
        }
    }

    struct TodoCardRows: View {
        var state: LockScreenCardState
        var limit: Int

        var body: some View {
            if state.rows.isEmpty {
                Label("All done", systemImage: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: TodoCardRow.height)
            } else {
                // 줄 사이를 띄우지 않고 줄 안쪽에 여백을 둔다 → 누를 수 있는 자리가 빈틈없이 이어진다.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(state.rows.prefix(limit)) { row in
                        TodoCardRow(row: row, viewId: state.viewId, isWritable: state.isWritable)
                    }
                }
            }
        }
    }

    /// 카드 한 줄. 체크는 `ToggleCardTodoIntent` — 잠금을 풀지 않아도 된다.
    struct TodoCardRow: View {
        var row: LockScreenCardState.Row
        var viewId: String
        var isWritable: Bool
        @ScaledMetric(relativeTo: .subheadline) private var diameter: CGFloat = 17
        @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = TodoCardRow.height

        /// 기본 글자 크기에서 한 줄의 높이. 다섯 줄과 머리가 160pt 안에 들어가는 값이다.
        static let height: CGFloat = 22

        var body: some View {
            if isWritable, row.canToggle {
                Button(intent: ToggleCardTodoIntent(itemId: row.id, viewId: viewId, done: !row.isDone)) { label }
                    .buttonStyle(.plain)
                    // 위젯 줄과 같게 읽는다: "치약 사기, 체크 안 됨".
                    .accessibilityLabel(TodoItem(id: row.id, title: row.title, isDone: row.isDone).accessibilityDescription)
                    .accessibilityHint(Text(row.isDone ? "Marks as not done" : "Marks as done"))
            } else {
                label.accessibilityElement(children: .combine)
            }
        }

        var label: some View {
            let baselineOffset = diameter * 0.3
            return HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if isWritable {
                        CheckCircle(isDone: row.isDone, diameter: diameter)
                    } else {
                        Circle().fill(.secondary).frame(width: diameter / 3, height: diameter / 3).frame(width: diameter)
                    }
                }
                // 원의 중심을 글자 몸통 높이에 맞춘다.
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + baselineOffset }
                Text(row.title)
                    .font(.subheadline)
                    .strikethrough(row.isDone)
                    .foregroundStyle(row.isDone ? .secondary : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: height)
            .contentShape(.rect)
        }
    }
#endif
