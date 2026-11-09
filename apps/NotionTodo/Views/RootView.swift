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
    }

    var isCompact: Bool {
        #if os(iOS)
            sizeClass == .compact
        #else
            false
        #endif
    }
}

/// DB별 뷰 목록.
struct ViewSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: selection) {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.views) { view in
                        Label(view.name, systemImage: view.showsDone ? "checkmark.circle" : "circle")
                            .tag(view.id)
                    }
                }
            }
        }
        .navigationTitle("Notion Todo")
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

    var groups: [(title: String, views: [ViewSummary])] {
        var order: [String] = []
        var byTitle: [String: [ViewSummary]] = [:]
        for view in model.catalog {
            if byTitle[view.databaseTitle] == nil { order.append(view.databaseTitle) }
            byTitle[view.databaseTitle, default: []].append(view)
        }
        return order.map { ($0, byTitle[$0] ?? []) }
    }
}
