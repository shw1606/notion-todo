import AuthenticationServices
import DesignSystem
import NotionKit
import SwiftUI
import TodoCore

#if os(macOS)
    import AppKit
#endif

/// 소개 → 연결 → 시작할 목록 → 위젯 안내 (PLAN 3.2). 연결은 버튼 한 번(Notion 화면에서 "허용")이고,
/// 다음 화면은 알맞은 출발점을 미리 골라 두어 "시작" 한 번으로 끝난다.
struct OnboardingView: View {
    enum Step: Hashable { case token, source, widgets }

    @Environment(AppModel.self) private var model
    @State private var path: [Step] = []
    @State private var selectedViewId: String?

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeStep { path.append(.token) }
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .token: TokenStep()
                    case .source: SourceStep { viewId in
                        selectedViewId = viewId
                        path.append(.widgets)
                    }
                    case .widgets: WidgetGuideStep {
                        Task { if let selectedViewId { await model.finishOnboarding(viewId: selectedViewId) } }
                    }
                    }
                }
        }
        .onAppear {
            // 연결은 됐는데 고른 목록이 없을 때(설정의 "다른 DB 고르기" 등)는 바로 목록 고르기로.
            if model.credentials != nil, !model.needsReconnect, path.isEmpty { path = [.source] }
        }
        .onChange(of: model.signIns) {
            // 어느 방법으로든 연결되면 목록 고르기로. 토큰 화면에서 왔으면 그 화면은 뺀다.
            if path.isEmpty || path == [.token] { path = [.source] }
        }
    }
}

// MARK: - 1. 소개 + 연결

struct WelcomeStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL
    var onUseToken: () -> Void

    @State private var isWorking = false
    @State private var waitsForBrowser = false
    @State private var connecting: Task<Void, Never>?
    @State private var error: String?

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

                if model.needsReconnect {
                    Label("Your Notion connection ended. Connect again to pick up where you left off.", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                if model.isOAuthAvailable {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        StepRow(number: 1, title: "Sign in to Notion")
                        StepRow(
                            number: 2, title: "Select pages, then Allow access",
                            detail: "Picking pages is optional. Already keep todos in Notion? Check that page.")
                        StepRow(number: 3, title: "Start writing", detail: "We’ll make a memo database for you, or use yours.")
                    }
                    PrimaryButton(title: "Connect Notion", systemImage: "link", isWorking: isWorking, action: connect)
                    VStack(spacing: Spacing.xs) {
                        if waitsForBrowser {
                            Text("Finish in your browser. You’ll come back here when you allow access.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        if isWorking {
                            Button("Cancel", action: cancel)
                        } else {
                            Button("Use a token instead", action: onUseToken)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                } else {
                    Text("Create a token in Notion and paste it here. It takes about a minute.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    PrimaryButton(title: "Connect with a token", systemImage: "key", isWorking: false, action: onUseToken)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: model.browserSignInOutcome) { _, outcome in
            guard let outcome else { return }
            error = outcome.error
            cancel()
        }
    }

    func connect() {
        error = nil
        isWorking = true
        connecting = Task {
            do {
                waitsForBrowser = try await model.connectNotion(session: webAuthenticationSession, openURL: openURL)
            } catch {
                if !Task.isCancelled { self.error = ConnectionError.message(for: error) }
            }
            if !Task.isCancelled, !waitsForBrowser { isWorking = false }
        }
    }

    /// 브라우저가 창을 못 띄우거나 사용자가 그만둘 때 갇히지 않게.
    func cancel() {
        connecting?.cancel()
        connecting = nil
        AppModel.pendingBrowserSignIn = nil
        waitsForBrowser = false
        isWorking = false
    }
}

// MARK: - 2. 토큰으로 연결

/// OAuth 함수 없이 쓸 때. 개인 액세스 토큰은 내 권한을 그대로 써서 페이지를 따로 공유하지 않아도 된다.
struct TokenStep: View {
    static let tokensURL = URL(string: "https://www.notion.so/developers/tokens")!

    @Environment(AppModel.self) private var model

    @State private var token = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                StepRow(number: 1, title: "Create a token", detail: "In Notion, choose New token, select Notion API, then Create token.")
                Link(destination: Self.tokensURL) {
                    Label("Open Notion", systemImage: "arrow.up.forward.app")
                }
                .foregroundStyle(Color.memoAccent)
                StepRow(number: 2, title: "Paste it here", detail: "We check it with Notion right away.")
                HStack(spacing: Spacing.s) {
                    SecureField("Token", text: $token, prompt: Text(verbatim: "ntn_…"))
                        .labelsHidden()
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .onSubmit(connect)
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { @MainActor in
                            token = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            connect()
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                }
                PrimaryButton(title: "Connect", systemImage: nil, isWorking: isWorking, action: connect)
                    .disabled(token.isEmpty)
            } footer: {
                Text("A personal access token sees what you can see in Notion, so there’s nothing to share. Internal integration tokens work too.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connect with a token")
        .onChange(of: token) { old, new in
            // ⌘V로 한 번에 붙여 넣으면 바로 확인한다.
            if old.isEmpty, Self.looksLikeToken(new) { connect() }
        }
    }

    static func looksLikeToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("ntn_") || trimmed.hasPrefix("secret_")) && trimmed.count >= 40
            && !trimmed.contains(where: \.isWhitespace)
    }

    func connect() {
        guard !token.isEmpty, !isWorking else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                let credentials = try await model.services.auth.signIn(internalToken: token)
                token = ""
                await model.didSignIn(credentials)
            } catch NotionError.unauthorized {
                error = String(localized: "Notion didn’t accept this token. Copy it again. It starts with ntn_.")
            } catch {
                self.error = ConnectionError.message(for: error)
            }
        }
    }
}

// MARK: - 3. 시작할 목록

/// 연결 직후. 이 앱이 만든 메모 DB가 보이면 그것, 아니면 새 메모 DB(Notion "비공개"에 만든다)를 골라 둔다.
/// 쓰던 DB는 아래에서 고른다. DB 목록은 검색 한 번이라 큰 워크스페이스에서도 바로 뜬다.
struct SourceStep: View {
    enum Choice: Hashable {
        case newDatabase
        case database(String)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL
    var onChosen: (String) -> Void

    @State private var databases: [DatabaseChoice] = []
    @State private var choice = Choice.newDatabase
    @State private var isLoading = true
    @State private var isStarting = false
    @State private var error: String?

    private let template = StarterTemplate.forCurrentLocale

    var body: some View {
        List {
            if let workspace = model.credentials?.workspaceName {
                Label("Connected to \(workspace)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            Section {
                option(
                    .newDatabase, icon: "plus.square.on.square", title: Text("New memo database"),
                    detail: Text("Adds “\(template.databaseTitle)” to Private in your Notion sidebar. Just a memo and a checkbox."))
            }
            Section {
                if isLoading {
                    HStack(spacing: Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text("Looking for your databases…").foregroundStyle(.secondary)
                    }
                } else if databases.isEmpty {
                    Text("Databases with a checkbox or status show up here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(databases) { database in
                        option(
                            .database(database.id), icon: "checklist",
                            title: database.title.isEmpty ? Text("Untitled") : Text(verbatim: database.title),
                            detail: Text(description(database)))
                    }
                }
                if model.isOAuthAvailable, model.credentials?.kind == .oauth {
                    Button("Don’t see yours? Select it in Notion…", action: selectMorePages)
                        .disabled(isStarting)
                }
            } header: {
                Text("Or use one you have")
            } footer: {
                if model.credentials?.kind == .internalToken {
                    Text("Using an internal integration? In Notion, open the page and add it under ••• → Connections.")
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: "Start", systemImage: nil, isWorking: isStarting, action: start)
                .disabled(isLoading)
                .padding(Spacing.l)
                .frame(maxWidth: 560)
        }
        .navigationTitle("Pick a list")
        .task { await load() }
        .refreshable { await load() }
        // Notion에서 페이지를 더 고르고 돌아오면 다시 찾는다.
        .onChange(of: model.signIns) { Task { await load() } }
        .onChange(of: model.browserSignInOutcome) { _, outcome in if let message = outcome?.error { error = message } }
    }

    func option(_ value: Choice, icon: String, title: Text, detail: Text) -> some View {
        let isSelected = choice == value
        return Button {
            choice = value
        } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.memoAccent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    title
                    detail.font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.memoAccent : Color.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .disabled(isStarting)
    }

    /// 체크하면 무엇이 바뀌는지 한 줄로.
    func description(_ database: DatabaseChoice) -> String {
        switch database.completionTarget {
        case .checkbox(let name)?: String(localized: "Checking off ticks “\(name)”")
        case .status(let name, let done)?: String(localized: "Checking off sets \(name) to “\(done)”")
        case nil: String(localized: "What gets checked depends on the view")
        }
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            databases = try await model.repository.databaseChoices()
            if let starter = databases.first(where: \.isStarter) { choice = .database(starter.id) }
        } catch {
            self.error = ConnectionError.message(for: error)
        }
    }

    func start() {
        isStarting = true
        error = nil
        Task {
            defer { isStarting = false }
            do {
                let view: ViewSummary
                switch choice {
                case .newDatabase: view = try await model.repository.createStarterDatabase(template: template)
                case .database(let id): view = try await model.repository.startingView(dataSourceId: id)
                }
                onChosen(view.id)
            } catch {
                self.error = ConnectionError.message(for: error)
            }
        }
    }

    /// 다시 연결하면 Notion이 페이지 선택 화면을 다시 보여준다. 돌아오면 `signIns`가 늘어 다시 찾는다.
    func selectMorePages() {
        Task {
            do {
                _ = try await model.connectNotion(session: webAuthenticationSession, openURL: openURL)
            } catch {
                self.error = ConnectionError.message(for: error)
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
                #if os(macOS)
                    guide(
                        "menubar.dock.rectangle", "Desktop",
                        "Control-click the desktop, choose Edit Widgets, and drag Todo Widget out.")
                    guide(
                        "bell.badge", "Notification Center",
                        "Click the date and time in the menu bar, then Edit Widgets at the bottom.")
                    guide(
                        "menubar.arrow.up.rectangle", "Menu bar",
                        "Jot something down from the menu bar icon. It stays after you close the window.")
                #else
                    let isPad = UIDevice.current.userInterfaceIdiom == .pad
                    guide(
                        isPad ? "apps.ipad" : "apps.iphone", "Home Screen",
                        "Touch and hold the Home Screen, tap Edit → Add Widget, and choose Todo Widget.")
                    guide(
                        isPad ? "lock.ipad" : "lock.iphone", "Lock Screen",
                        "Touch and hold the Lock Screen, tap Customize → Lock Screen, then add Memos. You can check items off without unlocking.")
                    guide(
                        "switch.2", "Control Center",
                        isPad
                            ? "Add the “Add Memo” control to jot something down from anywhere."
                            : "Add the “Add Memo” control to jot something down from anywhere — or put it on the Action button.")
                #endif
                PrimaryButton(title: "Start writing", systemImage: nil, isWorking: false, action: onDone)
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

// MARK: - 공용

/// 번호 붙은 한 줄 안내.
struct StepRow: View {
    var number: Int
    var title: LocalizedStringKey
    var detail: LocalizedStringKey?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.memoOnAccent)
                .frame(width: 24, height: 24)
                .background(Color.memoAccent, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 화면마다 하나인 큰 버튼. 일하는 동안은 진행 표시로 바뀐다.
struct PrimaryButton: View {
    var title: LocalizedStringKey
    var systemImage: String?
    var isWorking: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // 글자 자리를 지켜서 진행 표시로 바뀌어도 버튼 크기가 그대로다.
                Group {
                    if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
                }
                .opacity(isWorking ? 0 : 1)
                if isWorking { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xxs)
        }
        .buttonStyle(.glassProminent)
        .tint(.memoAccent)
        .controlSize(.large)
        .disabled(isWorking)
    }
}

/// 연결 실패를 알아들을 수 있는 말로.
enum ConnectionError {
    static func message(for error: Error) -> String {
        switch error {
        case let error as NotionError where error.isOffline:
            String(localized: "You’re offline. Check your connection and try again.")
        case NotionError.unauthorized:
            String(localized: "Notion ended this connection. Go back and connect again.")
        case is URLError:
            String(localized: "Couldn’t reach the sign-in server. Check your connection and try again.")
        case is AuthError:
            String(localized: "Notion didn’t finish connecting. Try again.")
        case TodoError.nowhereToCreate:
            String(localized: "There’s no page to put it in. In Notion, add a page to your integration under ••• → Connections, then try again.")
        case TodoError.noView:
            String(localized: "This database has no table or list view. Add one in Notion, or pick another.")
        default:
            String(localized: "Something went wrong: \(error.localizedDescription)")
        }
    }
}

extension AppModel {
    /// "Notion 연결하기". 연결되면 `signIns`가 늘고 화면이 넘어간다. 다시 하면 Notion에서 페이지를 더 고를 수 있다.
    /// iOS와 기본 브라우저가 Safari인 Mac은 인증 창을 쓰고 끝날 때까지 기다린다(창을 닫거나 Notion에서 취소해도 오류 없음).
    /// 그 밖의 Mac은 기본 브라우저 탭으로 열고 바로 true를 돌려준다 — 결과는 앱 주소로 와서 `finishBrowserSignIn`이 마친다.
    func connectNotion(session: WebAuthenticationSession, openURL: OpenURLAction) async throws -> Bool {
        guard let config = services.configuration.oauth else { return false }
        let pkce = PKCE()
        #if os(macOS)
            if !Self.authWindowWorks {
                Self.pendingBrowserSignIn = pkce
                openURL(config.authorizeURL(pkce: pkce))
                return true
            }
        #endif
        let callback: URL
        do {
            callback = try await session.authenticate(
                using: config.authorizeURL(pkce: pkce),
                callback: .customScheme(OAuthConfig.callbackScheme),
                preferredBrowserSession: nil,
                additionalHeaderFields: [:])
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return false
        }
        do {
            await didSignIn(try await services.auth.completeSignIn(callback: callback, pkce: pkce))
        } catch AuthError.canceled {}
        return false
    }

    #if os(macOS)
        /// 인증 창(ASWebAuthenticationSession)은 Safari에서만 믿을 만하다. Chrome 계열이 기본 브라우저면
        /// 두 번째부터 창이 뜨지 않고 멈추는 macOS 문제가 있다 (Apple 개발자 포럼 724366).
        static var authWindowWorks: Bool {
            guard let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://www.notion.so")!) else {
                return true
            }
            return Bundle(url: browser)?.bundleIdentifier?.hasPrefix("com.apple.Safari") ?? true
        }
    #endif
}

extension View {
    @ViewBuilder func navigationBarBackButtonHiddenCompat() -> some View {
        navigationBarBackButtonHidden(true)
    }
}
