#if os(macOS)
    import DesignSystem
    import SwiftUI
    import TodoCore

    /// Mac 메뉴 막대 빠른 기록: 입력 바 + 상위 5개 (PLAN 3.5).
    struct MenuBarQuickAdd: View {
        @Environment(AppModel.self) private var model
        @Environment(\.openWindow) private var openWindow
        @FocusState private var focus: ComposerField?

        var body: some View {
            @Bindable var model = model
            VStack(alignment: .leading, spacing: Spacing.s) {
                if model.phase == .ready {
                    HStack {
                        Text(model.currentSummary?.name ?? "").font(.headline)
                        Spacer()
                        Text("\(model.items.filter { !$0.isDone }.count)")
                            .font(.memoCount(.title3))
                            .foregroundStyle(Color.memoAccent)
                    }
                    ForEach(model.displayItems.prefix(5)) { item in
                        HStack(spacing: Spacing.xs) {
                            if model.isWritable {
                                Button { model.toggle(item) } label: { CheckCircle(isDone: item.isDone, isPending: item.isPending, diameter: 16) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(item.accessibilityDescription)
                                    .accessibilityValue(item.accessibilityStatus)
                            }
                            TodoRowContent(item: item, lineLimit: 1, showsDue: false)
                        }
                    }
                    if model.displayItems.isEmpty {
                        Text("All done").foregroundStyle(.secondary)
                    }
                    GlassComposer(text: $model.composerText, focus: $focus, field: .main) { model.add() }
                        .padding(.horizontal, -Spacing.m)
                } else {
                    Text("Open Notion Todo to sign in.").foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Button("Open Notion Todo") {
                        NSApp.activate()
                        openWindow(id: "main")
                    }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(.borderless)
            }
            .padding(Spacing.m)
            .frame(width: 320)
            .onAppear { focus = .main }
        }
    }
#endif
