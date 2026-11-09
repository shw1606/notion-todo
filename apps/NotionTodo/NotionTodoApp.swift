import AppIntents
import DesignSystem
import SwiftUI
import TodoCore

@main
struct NotionTodoApp: App {
    #if os(macOS)
        /// 메뉴 막대 빠른 기록·설정 창이 쓰는 모델. 창마다의 모델과 별개다.
        @State private var utilityModel = AppModel()
        @AppStorage("showsMenuBarExtra") private var showsMenuBarExtra = true
    #endif

    var body: some Scene {
        WindowGroup(id: "main") {
            WindowRoot()
        }
        .commands { AppCommands() }
        #if os(macOS)
            .defaultSize(width: 820, height: 620)
        #endif

        #if os(macOS)
            Settings {
                SettingsView()
                    .environment(utilityModel)
                    .tint(.memoAccent)
                    .frame(width: 460)
                    .task { if utilityModel.phase == .launching { await utilityModel.start() } }
            }

            MenuBarExtra(isInserted: $showsMenuBarExtra) {
                MenuBarQuickAdd()
                    .environment(utilityModel)
                    .tint(.memoAccent)
                    .task { if utilityModel.phase == .launching { await utilityModel.start() } }
            } label: {
                Label("Notion Todo", systemImage: "checklist")
            }
            .menuBarExtraStyle(.window)
        #endif
    }
}

/// 창 하나. 창마다 자기 모델을 가져서 iPad Stage Manager·Mac 여러 창에서 각자 다른 뷰를 연다 (PLAN 3.4).
struct WindowRoot: View {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView()
            .environment(model)
            .tint(.memoAccent)
            .focusedSceneValue(\.appModel, model)
            .task { await model.start() }
            .onOpenURL { model.handle(url: $0) }
            // 위젯·로그인에서 여는 앱 주소를 새 창이 아니라 열려 있는 창이 받는다 (Mac은 기본이 새 창).
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.becameActive() } }
            }
    }
}

extension FocusedValues {
    @Entry var appModel: AppModel?
}

/// 메뉴 막대(Mac)·하드웨어 키보드(iPad) 단축키. 지금 앞에 있는 창의 모델에 보낸다.
struct AppCommands: Commands {
    @FocusedValue(\.appModel) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // 메모·미리 알림처럼 ⌘N은 새 메모, 새 창은 ⌥⌘N.
        CommandGroup(replacing: .newItem) {
            Button("New Memo") { model?.requestComposerFocus() }
                .keyboardShortcut("n")
                .disabled(model?.phase != .ready)
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh") { Task { await model?.refresh() } }
                .keyboardShortcut("r")
                .disabled(model?.phase != .ready)
        }
    }
}

struct NotionTodoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddMemoIntent(),
            phrases: [
                "Add a memo in \(.applicationName)",
                "Write down in \(.applicationName)",
            ],
            shortTitle: "Add Memo",
            systemImageName: "square.and.pencil")
    }
}
