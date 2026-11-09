import DesignSystem
import SwiftUI
import TodoCore
import WidgetKit

/// 계정 · 연결된 뷰 · 위젯 · 정보 (PLAN 3.6).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsSignOut = false
    #if os(macOS)
        @AppStorage("showsMenuBarExtra") private var showsMenuBarExtra = true
    #endif

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Notion", value: model.credentials?.ownerName ?? "—")
                if let workspace = model.credentials?.workspaceName {
                    LabeledContent("Workspace", value: workspace)
                }
                LabeledContent(
                    "Connection",
                    value: model.credentials?.kind == .oauth
                        ? String(localized: "Signed in with Notion") : String(localized: "Integration token"))
                Button("Sign Out", role: .destructive) { confirmsSignOut = true }
            }

            Section {
                ForEach(model.catalog) { view in
                    LabeledContent("\(view.name)", value: view.databaseTitle)
                }
                Button("Reload views") { Task { await model.refreshCatalog() } }
                Button("Choose another database…") { model.phase = .onboarding }
            } header: {
                Text("Views")
            } footer: {
                Text("To add databases, sign in again and select more pages in Notion.")
            }

            Section {
                Button("Refresh widgets now") {
                    Task {
                        await model.refresh()
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }
                #if os(macOS)
                    Toggle("Show in menu bar", isOn: $showsMenuBarExtra)
                #endif
            } header: {
                Text("Widgets")
            } footer: {
                Text("Widgets refresh every 15–60 minutes as the system allows. Changes you make in this app or in a widget show up right away.")
            }

            Section("About") {
                Link("Source code on GitHub", destination: URL(string: "https://github.com/shw1606/notion-todo")!)
                Text("Your data only travels between this device and Notion. No analytics, no tracking.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar {
            #if os(iOS)
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            #endif
        }
        .confirmationDialog("Sign out of Notion?", isPresented: $confirmsSignOut) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await model.signOut()
                    dismiss()
                }
            }
        } message: {
            Text("Cached memos on this device will be removed. Your Notion data stays as it is.")
        }
    }
}
