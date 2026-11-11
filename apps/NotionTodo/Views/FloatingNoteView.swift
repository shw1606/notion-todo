#if os(macOS)
    import DesignSystem
    import SwiftUI
    import TodoCore

    /// 떠 있는 메모의 내용: 뷰 이름 · 남은 개수 · 목록 · 입력 바. 순서와 섹션은 앱 창에서 정한 대로 따른다.
    struct FloatingNoteView: View {
        @Environment(AppModel.self) private var model
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @AppStorage(FloatingNote.Key.isShown) private var isShown = true
        @AppStorage(FloatingNote.Key.isCollapsed) private var isCollapsed = false
        @FocusState private var focus: ComposerField?

        static let checkDiameter: CGFloat = 16

        var body: some View {
            VStack(spacing: 0) {
                header
                // 접으면 머리 줄(뷰 이름·남은 개수)만 남는다.
                if !isCollapsed {
                    switch model.phase {
                    case .ready:
                        list
                        bottomBar
                    case .onboarding:
                        signedOut
                    case .launching:
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // 뒤가 비치는 바탕 위에 창 배경색을 옅게 덧칠한다. 바탕만으로는 다크 모드에서 흰 문서 위에 놓였을 때
            // 밝아져서 흰 글씨와 체크 원이 묻힌다 (라이트 모드에서 어두운 화면 위도 마찬가지).
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.25))
            // 제목 막대 자리까지 쓴다 (단추는 숨겨 두었다).
            .ignoresSafeArea(.container, edges: .top)
            // 이 창은 거의 늘 키 창이 아니다. 그래도 첫 클릭이 그대로 체크·메뉴에 닿게 한다 (두 번 누르지 않게).
            .allowsWindowActivationEvents(true)
        }

        // MARK: 머리

        var header: some View {
            HStack(spacing: Spacing.xs) {
                viewTitle
                Spacer(minLength: 0)
                if model.isOffline {
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.secondary)
                        .help(Text("Offline — changes will sync later"))
                        .accessibilityLabel(Text("Offline"))
                }
                if model.phase == .ready {
                    Text("\(model.items.filter { !$0.isDone }.count)")
                        .font(.memoCount(.body))
                        .foregroundStyle(Color.memoAccent)
                }
                collapseButton
                moreMenu
            }
            .padding(.leading, Spacing.s)
            .padding(.trailing, Spacing.xxs)
            .frame(height: FloatingNote.headerHeight)
            .contentShape(.rect)
            // 스티커처럼 머리를 두 번 클릭해 접고 편다.
            .onTapGesture(count: 2) { FloatingNote.shared.toggleCollapsed() }
            // 머리를 잡고 끌면 창이 움직인다.
            .gesture(WindowDragGesture())
        }

        @ViewBuilder var viewTitle: some View {
            // 로그아웃한 뒤에는 보던 뷰 이름 대신 앱 이름을 보여 준다.
            let name = (model.phase == .ready ? model.currentSummary?.name : nil) ?? String(localized: "Todo Widget")
            if model.phase == .ready, model.catalog.count > 1 {
                Menu {
                    ForEach(model.catalog) { view in
                        Button {
                            Task { await model.open(viewId: view.id) }
                        } label: {
                            if view.id == model.currentViewId {
                                Label("\(view.name) · \(view.databaseTitle)", systemImage: "checkmark")
                            } else {
                                Text("\(view.name) · \(view.databaseTitle)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(verbatim: name).font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("Change view"))
                .accessibilityValue(Text(verbatim: name))
            } else {
                Text(verbatim: name).font(.headline).lineLimit(1)
            }
        }

        var collapseButton: some View {
            Button { FloatingNote.shared.toggleCollapsed() } label: {
                Image(systemName: isCollapsed ? "chevron.compact.down" : "chevron.compact.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? Text("Expand") : Text("Collapse"))
            .accessibilityLabel(isCollapsed ? Text("Expand") : Text("Collapse"))
        }

        var moreMenu: some View {
            Menu {
                Button(isCollapsed ? "Expand" : "Collapse") { FloatingNote.shared.toggleCollapsed() }
                Button("Open Todo Widget") {
                    FloatingNote.openApp(model.currentViewId.map(DeepLink.view) ?? DeepLink.onboarding)
                }
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.phase != .ready)
                Divider()
                // 다시 켜는 곳은 설정·보기 메뉴·메뉴 막대 창.
                Button("Hide Floating Note") { isShown = false }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("More"))
        }

        // MARK: 목록

        var list: some View {
            let rows = model.rows
            return ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .padding(.bottom, Spacing.xs)
                .animation(reduceMotion ? Motion.reduced : Motion.check, value: rows.map(\.id))
            }
            .overlay {
                if rows.isEmpty, !model.isRefreshing {
                    Text("All done").foregroundStyle(.secondary)
                }
            }
        }

        @ViewBuilder func rowView(_ row: LayoutRow) -> some View {
            // 섹션에 든 줄은 카드 여백만큼 더 들여 쓴다.
            let inset = row.sectionId == nil ? Spacing.s : Spacing.s + Spacing.xs
            Group {
                switch row.kind {
                case .item(let item):
                    itemRow(item)
                        .padding(.bottom, row.isLastInSection ? Spacing.xxs : 0)
                case .header(let title, let count):
                    HStack(spacing: Spacing.xs) {
                        Circle()
                            .fill(row.tint?.color ?? .secondary)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(verbatim: LayoutSection.displayTitle(title))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                        if count > 0 {
                            Text("\(count)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    // 카드 위쪽 여백만큼 내려서 색 배경 안에 오게 한다.
                    .padding(.top, SectionCardBackground.topGap + 6)
                    .padding(.bottom, row.isLastInSection ? 6 : 2)
                }
            }
            .padding(.horizontal, inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if let tint = row.tint {
                    SectionCardBackground(tint: tint, isFirst: row.isHeader, isLast: row.isLastInSection)
                }
            }
        }

        func itemRow(_ item: TodoItem) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Group {
                    if model.isWritable {
                        Button { model.toggle(item) } label: {
                            CheckCircle(isDone: item.isDone, isPending: item.isPending, diameter: Self.checkDiameter)
                                .padding(.vertical, 3)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.accessibilityDescription)
                        .accessibilityValue(item.accessibilityStatus)
                    } else {
                        Circle().fill(.secondary).frame(width: 5, height: 5)
                            .frame(width: Self.checkDiameter, height: Self.checkDiameter)
                            .accessibilityHidden(true)
                    }
                }
                // 원의 가운데를 첫 줄 글자 높이에 맞춘다 (여러 줄이어도 첫 줄 옆에 온다).
                .alignmentGuide(.firstTextBaseline) { [diameter = Self.checkDiameter] in $0[VerticalAlignment.center] + diameter * 0.27 }
                TodoRowContent(item: item, lineLimit: 2, showsDue: model.currentView?.datePropertyId != nil)
            }
            .padding(.vertical, 2)
        }

        // MARK: 아래

        var bottomBar: some View {
            @Bindable var model = model
            return VStack(spacing: Spacing.xxs) {
                if let undo = model.undo {
                    UndoToast(message: undo.message) { undo.perform() }
                        .transition(.opacity)
                }
                if let error = model.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, Spacing.s)
                        .onTapGesture { model.lastError = nil }
                }
                GlassComposer(text: $model.composerText, focus: $focus, field: .main) { model.add() }
                    // 작은 창이라 입력 바의 좌우 여백을 줄인다.
                    .padding(.horizontal, Spacing.xs - Spacing.m)
            }
            .animation(.smooth, value: model.undo?.id)
        }

        var signedOut: some View {
            VStack(spacing: Spacing.xs) {
                Text("Open Todo Widget to sign in.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Todo Widget") { FloatingNote.openApp(DeepLink.onboarding) }
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
#endif
