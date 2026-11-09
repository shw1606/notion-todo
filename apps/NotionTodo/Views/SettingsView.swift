import DesignSystem
import SwiftUI
import TodoCore
import WidgetKit

/// 계정 · 고른 DB · 위젯 · 정보 (PLAN 3.6).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsSignOut = false
    @State private var addsDatabase = false
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
                        ? String(localized: "Signed in with Notion") : String(localized: "Access token"))
                Button("Sign Out", role: .destructive) { confirmsSignOut = true }
            }

            Section {
                ForEach(model.databases) { database in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: database.title)
                            Text(verbatim: database.views.map(\.name).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.databases.count > 1 {
                            Button("Remove") { Task { await model.removeDatabase(database.id) } }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Text("Remove “\(database.title)”"))
                        }
                    }
                }
                Button("Add Database…") { addsDatabase = true }
                Button("Reload views") { Task { await model.refreshCatalog() } }
            } header: {
                Text("Databases")
            } footer: {
                Text("Only these show up in the app and widgets. Removing one leaves it as it is in Notion.")
            }

            Section {
                if let fetched = model.lastFetchedAt {
                    LabeledContent("Last updated") { Text(fetched, style: .relative) }
                }
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
                Link("License (MIT)", destination: URL(string: "https://github.com/shw1606/notion-todo/blob/main/LICENSE")!)
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
        .sheet(isPresented: $addsDatabase) { AddDatabaseSheet() }
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
