#if os(iOS)
    import ActivityKit
    import SwiftUI
    import TodoCore
    import WidgetKit

    /// 설정의 "잠금 화면 카드" 칸 (iPhone·iPad).
    struct LockScreenCardSettings: View {
        @Environment(AppModel.self) private var model
        @Environment(\.openURL) private var openURL
        @AppStorage(LockScreenCard.Key.isOn, store: LockScreenCard.defaults) private var isOn = false
        @AppStorage(LockScreenCard.Key.viewId, store: LockScreenCard.defaults) private var chosenViewId = ""
        /// 설정 ▸ 앱에서 실시간 현황을 꺼 두면 카드를 띄울 수 없다.
        @State private var isAllowed = LockScreenCard.isAllowed

        var body: some View {
            Section {
                Toggle("Show memos on the Lock Screen", isOn: $isOn)
                if isOn, model.catalog.count > 1 {
                    Picker("View", selection: viewSelection) {
                        ForEach(model.catalog) { view in
                            Text(verbatim: "\(view.name) · \(view.databaseTitle)").tag(view.id)
                        }
                    }
                }
                if isOn, !isAllowed {
                    Button("Turn on Live Activities in Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            } header: {
                Text("Lock Screen Card")
            } footer: {
                Text("A large card with your memos stays on the Lock Screen, and you can check them off right there. iOS takes a card down after 8 to 12 hours, so a new one takes its place — the screen lights up briefly when it does, never at night. After about a day and a half without opening this app, the card goes away until you open it or check a memo in a widget.")
            }
            .onChange(of: isOn) { _, _ in
                // 위젯의 체크가 어느 인텐트로 갈지도 이 값으로 정해진다.
                WidgetCenter.shared.reloadAllTimelines()
                Task { await LockScreenCard.sync(start: .ifMissing) }
            }
            .task {
                for await allowed in ActivityAuthorizationInfo().activityEnablementUpdates {
                    isAllowed = allowed
                    // 다시 허용했으면 바로 띄운다.
                    if allowed, isOn { await LockScreenCard.sync(start: .ifMissing) }
                }
            }
        }

        /// 고른 적이 없거나 고른 뷰가 목록에서 빠졌으면 할 일을 보여 주는 뷰.
        var viewSelection: Binding<String> {
            Binding {
                model.catalog.contains { $0.id == chosenViewId } ? chosenViewId : model.catalog.preferredDefault?.id ?? ""
            } set: { id in
                chosenViewId = id
                Task { await LockScreenCard.sync(fetch: true) }
            }
        }
    }
#endif
