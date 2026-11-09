import AuthenticationServices
import DesignSystem
import NotionKit
import SwiftUI
import TodoCore

/// 소개 → 로그인 → DB 고르기 → 위젯 안내 (PLAN 3.2).
struct OnboardingView: View {
    enum Step: Hashable { case welcome, source, widgets }

    @Environment(AppModel.self) private var model
    @State private var path: [Step] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeStep { path.append(.source) }
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .welcome: EmptyView()
                    case .source: SourceStep { viewId in
                        Task {
                            selectedViewId = viewId
                            path.append(.widgets)
                        }
                    }
                    case .widgets: WidgetGuideStep {
                        Task { if let selectedViewId { await model.finishOnboarding(viewId: selectedViewId) } }
                    }
                    }
                }
        }
        .onAppear {
            if model.credentials != nil, path.isEmpty { path = [.source] }
        }
    }

    @State private var selectedViewId: String?
}

// MARK: - 1·2. 소개 + 로그인

struct WelcomeStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    var onSignedIn: () -> Void

    @State private var isWorking = false
    @State private var error: String?
    @State private var showsTokenEntry = false
    @State private var token = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Spacer(minLength: Spacing.l)
                Image(systemName: "checklist")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(Color.memoAccent)
                    .accessibilityHidden(true)
                Text("Write it down.\nCheck it off from your widget.")
                    .font(.largeTitle.weight(.bold))
                Text("Your memos live in your own Notion database. They never pass through our servers.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: Spacing.s) {
                    if model.isOAuthAvailable {
                        Button(action: signInWithNotion) {
                            Label("Sign in with Notion", systemImage: "person.crop.circle")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Spacing.xxs)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.memoAccent)
                        .controlSize(.large)
                        .disabled(isWorking)
                        Text("On the next screen, pick the page that holds your todo database — or any page where a new one should go.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    DisclosureGroup(isExpanded: $showsTokenEntry) {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            Text("Building it yourself? Create an internal integration in Notion, share your database with it, and paste its token.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            SecureField("ntn_…", text: $token)
                                .textContentType(.password)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                            Button("Connect", action: signInWithToken)
                                .buttonStyle(.glass)
                                .disabled(token.isEmpty || isWorking)
                        }
                        .padding(.top, Spacing.xs)
                    } label: {
                        Text("Use an integration token")
                    }
                }
                if isWorking { ProgressView() }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { showsTokenEntry = !model.isOAuthAvailable }
    }

    func signInWithNotion() {
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                guard try await model.signInWithNotion(using: webAuthenticationSession) else { return }
                onSignedIn()
            } catch {
                self.error = String(localized: "Couldn’t sign in: \(error.localizedDescription)")
            }
        }
    }

    func signInWithToken() {
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                let credentials = try await model.services.auth.signIn(internalToken: token)
                token = ""
                await model.didSignIn(credentials)
                onSignedIn()
            } catch {
                self.error = String(localized: "That token didn’t work. Check it and try again.")
            }
        }
    }
}

// MARK: - 3. DB 고르기

struct SourceStep: View {
    @Environment(AppModel.self) private var model
    var onChosen: (String) -> Void

    @State private var pages: [Page] = []
    @State private var isLoading = true
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if pages.isEmpty, !isLoading {
                    Text("No pages are shared yet. Sign in again and select a page.")
                        .foregroundStyle(.secondary)
                }
                ForEach(pages.prefix(8), id: \.id) { page in
                    Button {
                        create(under: page)
                    } label: {
                        Label(page.titleText.isEmpty ? String(localized: "Untitled") : page.titleText, systemImage: "doc")
                    }
                    .disabled(isCreating)
                }
            } header: {
                Text("Recommended: create a new memo database")
            } footer: {
                Text("Creates “Memo · Done · Created” with a To do view and a Done view under the page you pick.")
            }

            if !model.catalog.isEmpty {
                Section("Or use a view you already have") {
                    ForEach(model.catalog) { view in
                        Button {
                            onChosen(view.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(view.name) · \(view.databaseTitle)")
                                Text(description(view)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .overlay { if isLoading || isCreating { ProgressView() } }
        .navigationTitle("Choose a database")
        .task { await load() }
        .refreshable { await load() }
    }

    /// 뷰 해석 결과를 한 줄로 알려준다 — 체크하면 무엇이 바뀌는지.
    func description(_ view: ViewSummary) -> String {
        guard view.isWritable else { return String(localized: "Read only — no checkbox or status to check off") }
        let action = switch view.completionTarget {
        case .checkbox(let name)?: String(localized: "Checking off ticks “\(name)”")
        case .status(let name, let done)?: String(localized: "Checking off sets \(name) to “\(done)”")
        case nil: String(localized: "Check off from widgets")
        }
        return view.showsDone ? "\(action) · \(String(localized: "Shows checked items"))" : action
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let pages = model.repository.client.searchPages()
            await model.refreshCatalog()
            self.pages = try await pages.filter { page in
                if case .dataSource = page.parent { return false }  // DB 항목 말고 일반 페이지만
                return true
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func create(under page: Page) {
        isCreating = true
        error = nil
        Task {
            defer { isCreating = false }
            do {
                let summary = try await model.repository.createStarterDatabase(parentPageId: page.id)
                await model.refreshCatalog()
                onChosen(summary.id)
            } catch {
                self.error = String(localized: "Couldn’t create the database: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 4. 위젯 안내

struct WidgetGuideStep: View {
    var onDone: () -> Void
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("Keep it in sight").font(.largeTitle.weight(.bold))
                guide(
                    "apps.iphone", "Home Screen",
                    "Touch and hold the Home Screen, tap Edit → Add Widget, and choose Notion Todo.")
                guide(
                    "lock.iphone", "Lock Screen",
                    "Touch and hold the Lock Screen, tap Customize → Lock Screen, then add Memos. You can check items off without unlocking.")
                guide(
                    "switch.2", "Control Center",
                    "Add the “Add Memo” control to jot something down from anywhere — or put it on the Action button.")
                guide(
                    "macbook", "Mac",
                    "Right-click the desktop → Edit Widgets. The menu bar icon is always one click away.")
                Button(action: onDone) {
                    Text("Start writing").frame(maxWidth: .infinity).padding(.vertical, Spacing.xxs)
                }
                .buttonStyle(.glassProminent)
                .tint(.memoAccent)
                .controlSize(.large)
            }
            .padding(Spacing.l)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationBarBackButtonHiddenCompat()
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            appeared = true
        }
    }

    func guide(_ icon: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.memoAccent)
                .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

extension AppModel {
    /// "Notion으로 로그인". 다시 하면 Notion 페이지 선택 화면이 다시 떠서 페이지를 더 고를 수 있다 (설정).
    /// 사용자가 창을 닫으면 false.
    func signInWithNotion(using session: WebAuthenticationSession) async throws -> Bool {
        guard let config = services.configuration.oauth else { return false }
        let pkce = PKCE()
        let callback: URL
        do {
            callback = try await session.authenticate(
                using: config.authorizeURL(pkce: pkce),
                callback: .https(host: config.callbackHost, path: config.callbackPath),
                preferredBrowserSession: nil,
                additionalHeaderFields: [:])
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return false
        }
        await didSignIn(try await services.auth.completeSignIn(callback: callback, pkce: pkce))
        return true
    }
}

extension View {
    @ViewBuilder func navigationBarBackButtonHiddenCompat() -> some View {
        navigationBarBackButtonHidden(true)
    }
}
