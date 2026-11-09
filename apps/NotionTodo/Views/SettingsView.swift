import AuthenticationServices
import DesignSystem
import SwiftUI
import TodoCore
import WidgetKit

/// 계정 · 연결된 뷰 · 위젯 · 정보 (PLAN 3.6).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
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
                if model.isOAuthAvailable {
                    Button("Select more pages in Notion…", action: selectMorePages)
                }
                Button("Choose another database…") { model.phase = .onboarding }
            } header: {
                Text("Views")
            } footer: {
                if model.credentials?.kind == .oauth {
                    Text("Databases on the pages you select in Notion show up here.")
                } else {
                    Text("To add databases, connect more pages to your integration in Notion.")
                }
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

    /// OAuth를 다시 실행하면 Notion이 페이지 선택 화면을 다시 보여준다.
    func selectMorePages() {
        Task {
            do {
                guard try await model.signInWithNotion(using: webAuthenticationSession) else { return }
                await model.refreshCatalog()
            } catch {
                model.lastError = String(localized: "Couldn’t sign in: \(error.localizedDescription)")
            }
        }
    }
}
