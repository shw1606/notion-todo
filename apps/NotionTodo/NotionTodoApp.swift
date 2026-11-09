import AppIntents
import SwiftUI
import TodoCore

@main
struct NotionTodoApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
        @AppStorage("showsMenuBarExtra") private var showsMenuBarExtra = true
    #endif

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .task { await model.start() }
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.becameActive() } }
                }
        }
        .commands { AppCommands(model: model) }
        #if os(macOS)
            .defaultSize(width: 820, height: 620)
        #endif

        #if os(macOS)
            Settings {
                SettingsView()
                    .environment(model)
                    .frame(width: 460)
            }

            MenuBarExtra(isInserted: $showsMenuBarExtra) {
                MenuBarQuickAdd()
                    .environment(model)
                    .task { if model.phase == .launching { await model.start() } }
            } label: {
                Label("Notion Todo", systemImage: "checklist")
            }
            .menuBarExtraStyle(.window)
        #endif
    }
}

/// 메뉴 막대(Mac)·하드웨어 키보드(iPad) 단축키 (PLAN 3.4).
struct AppCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Memo") { model.requestComposerFocus() }
                .keyboardShortcut("n")
                .disabled(model.phase != .ready)
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh") { Task { await model.refresh() } }
                .keyboardShortcut("r")
                .disabled(model.phase != .ready)
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
                "\(.applicationName)에 메모 추가",
            ],
            shortTitle: "Add Memo",
            systemImageName: "square.and.pencil")
    }
}
