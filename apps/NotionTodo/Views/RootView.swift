import DesignSystem
import SwiftUI
import TodoCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .launching:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .onboarding:
            OnboardingView()
        case .ready:
            MainView()
        }
    }
}

/// iPhone은 스택, iPad·Mac은 사이드바 분할 화면 (PLAN 3.3~3.5).
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        @Bindable var model = model
        Group {
            if isCompact {
                NavigationStack {
                    TodoListView(showsViewMenu: true)
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    ViewSidebar()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                } detail: {
                    NavigationStack {
                        TodoListView(showsViewMenu: false)
                    }
                }
            }
        }
        #if os(iOS)
            .sheet(isPresented: $model.showsSettings) {
                NavigationStack { SettingsView() }
            }
        #endif
        .sheet(isPresented: $model.showsAddDatabase) { AddDatabaseSheet() }
    }

    var isCompact: Bool {
        #if os(iOS)
            sizeClass == .compact
        #else
            false
        #endif
    }
}

/// 고른 DB별 뷰 목록. 아래 버튼으로 DB를 더하고, 문맥 메뉴로 뺀다.
struct ViewSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: selection) {
            ForEach(model.databases) { database in
                Section(database.title) {
                    ForEach(database.views) { view in
                        Label(view.name, systemImage: view.showsDone ? "checkmark.circle" : "circle")
                            .tag(view.id)
                            .contextMenu {
                                if model.databases.count > 1 {
                                    Button("Remove “\(database.title)” from Sidebar", systemImage: "minus.circle") {
                                        Task { await model.removeDatabase(database.id) }
                                    }
                                }
                            }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { model.showsAddDatabase = true } label: { Label("Add Database", systemImage: "plus") }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.m)
        }
        .navigationTitle("Todo Widget")
        .refreshable { await model.refreshCatalog() }
        .toolbar {
            #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showsSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            #endif
        }
    }

    var selection: Binding<String?> {
        Binding(
            get: { model.currentViewId },
            set: { id in if let id, id != model.currentViewId { Task { await model.open(viewId: id) } } })
    }
}

/// "DB 추가": 아직 고르지 않은 DB를 골라 목록에 더한다. 온보딩의 시작할 목록과 같은 화면이다.
struct AddDatabaseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SourceStep(purpose: .add) { viewId in
                dismiss()
                Task { await model.didAddDatabase(viewId: viewId) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 440, minHeight: 520)
        #endif
    }
}
