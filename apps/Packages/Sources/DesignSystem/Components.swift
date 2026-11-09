import SwiftUI
import TodoCore
import WidgetKit

// MARK: - 체크 원

/// 체크 상태는 색이 아니라 모양(채운 원 + 체크)으로 구분한다 → 위젯 tinted/vibrant 모드에서도 읽힌다.
public struct CheckCircle: View {
    var isDone: Bool
    var isPending: Bool
    var diameter: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    public init(isDone: Bool, isPending: Bool = false, diameter: CGFloat = Spacing.checkDiameter) {
        self.isDone = isDone
        self.isPending = isPending
        self.diameter = diameter
    }

    public var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isDone ? Color.memoAccent : Color.secondary, lineWidth: 1.5)
            if isDone {
                Circle().fill(Color.memoAccent)
                Image(systemName: "checkmark")
                    .font(.system(size: diameter * 0.5, weight: .bold))
                    .foregroundStyle(Color.memoOnAccent)
                    // 위젯 틴트·단색 모드에서는 색이 한 가지로 합쳐진다 → 체크 표시를 원에서 도려내 모양으로 남긴다.
                    .blendMode(renderingMode == .fullColor ? .normal : .destinationOut)
            }
        }
        .compositingGroup()
        .frame(width: diameter, height: diameter)
        .opacity(isPending ? 0.55 : 1)
        .accessibilityHidden(true)
    }
}

// MARK: - 날짜 칩

public struct DueChip: View {
    var due: String
    var now: Date

    public init(due: String, now: Date = .now) {
        self.due = due
        self.now = now
    }

    public var body: some View {
        if let label = Self.label(due, now: now) {
            Text(label.text)
                .font(.caption)
                .foregroundStyle(label.isOverdue ? Color.red : Color.secondary)
                .accessibilityLabel(Text("Due \(label.text)", bundle: .module))
        }
    }

    public struct Label: Equatable, Sendable {
        public var text: String
        public var isOverdue: Bool
    }

    nonisolated public static func label(_ due: String, now: Date = .now, calendar: Calendar = .current) -> Label? {
        guard let date = DayFormat.date(due, calendar: calendar) else { return nil }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        let text: String
        switch days {
        case 0: text = String(localized: "Today", bundle: .module)
        case 1: text = String(localized: "Tomorrow", bundle: .module)
        case -1: text = String(localized: "Yesterday", bundle: .module)
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            text = date.formatted(sameYear ? .dateTime.month().day() : .dateTime.year().month().day())
        }
        return Label(text: text, isOverdue: days < 0)
    }
}

// MARK: - 행 내용

/// 메모 한 줄. 앱 목록·위젯·메뉴 막대가 같이 쓴다.
public struct TodoRowContent: View {
    var item: TodoItem
    var lineLimit: Int
    var showsDue: Bool

    public init(item: TodoItem, lineLimit: Int = 3, showsDue: Bool = true) {
        self.item = item
        self.lineLimit = lineLimit
        self.showsDue = showsDue
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(item.title.isEmpty ? String(localized: "Untitled", bundle: .module) : item.title)
                .strikethrough(item.isDone)
                .foregroundStyle(item.isDone ? Color.secondary : Color.primary)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsDue, let due = item.due {
                DueChip(due: due)
            }
        }
    }
}

extension TodoItem {
    /// VoiceOver: "치약 사기, 체크 안 됨".
    public var accessibilityDescription: Text {
        let state = isDone
            ? String(localized: "Checked", bundle: .module) : String(localized: "Not checked", bundle: .module)
        return Text(verbatim: "\(title), \(state)")
    }

    /// VoiceOver 값: 아직 Notion에 반영되지 않은 변경이 있으면 알려준다.
    public var accessibilityStatus: Text {
        isPending ? Text("Waiting to sync", bundle: .module) : Text(verbatim: "")
    }
}

// MARK: - 유리 입력 바

/// 하단에 떠 있는 Liquid Glass 입력 바. 화면에서 직접 그리는 유일한 크롬이다 (PLAN 2.3).
public struct GlassComposer<Field: Hashable>: View {
    @Binding var text: String
    var focus: FocusState<Field?>.Binding
    var field: Field
    var placeholder: String?
    var onSubmit: () -> Void
    @Namespace private var glass

    public init(
        text: Binding<String>, focus: FocusState<Field?>.Binding, field: Field,
        placeholder: String? = nil,
        onSubmit: @escaping () -> Void
    ) {
        _text = text
        self.focus = focus
        self.field = field
        self.placeholder = placeholder
        self.onSubmit = onSubmit
    }

    var canSubmit: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var body: some View {
        GlassEffectContainer(spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                TextField(placeholder ?? String(localized: "Add a memo…", bundle: .module), text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .focused(focus, equals: field)
                    .submitLabel(.done)
                    .onSubmit(submit)
                    // 여러 줄 입력 필드는 iOS에서 Return이 줄바꿈이 된다 → Return은 언제나 "추가".
                    .onChange(of: text) { _, newValue in
                        guard newValue.contains("\n") else { return }
                        text = newValue.replacingOccurrences(of: "\n", with: "")
                        submit()
                    }
                    .accessibilityIdentifier("composer")
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
                    .frame(minHeight: Spacing.rowMinHeight)
                    // 바깥 용기(화면·창·시트) 모서리와 동심원. 멀리 떨어진 모서리는 최소 22pt.
                    .glassEffect(.regular.interactive(), in: .rect(corners: .concentric(minimum: .fixed(22))))
                    .glassEffectID("field", in: glass)
                if canSubmit {
                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(.memoAccent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(Text("Add", bundle: .module))
                    .glassEffectID("send", in: glass)
                }
            }
            .animation(.smooth(duration: 0.25), value: canSubmit)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.bottom, Spacing.xs)
    }

    func submit() {
        guard canSubmit else { return }
        onSubmit()
    }
}

// MARK: - 실행 취소 알림

public struct UndoToast: View {
    var message: String
    var undo: () -> Void

    public init(message: String, undo: @escaping () -> Void) {
        self.message = message
        self.undo = undo
    }

    public var body: some View {
        HStack(spacing: Spacing.s) {
            Text(message).lineLimit(1)
            Button(String(localized: "Undo", bundle: .module), action: undo)
                .fontWeight(.semibold)
                .tint(.memoAccent)
        }
        .font(.subheadline)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - 빈 상태

public struct AllDoneView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView {
            Label {
                Text("All done", bundle: .module)
            } icon: {
                Image(systemName: "sparkles").foregroundStyle(Color.memoAccent)
            }
        } description: {
            Text("Write down the next thing below.", bundle: .module)
        }
    }
}
