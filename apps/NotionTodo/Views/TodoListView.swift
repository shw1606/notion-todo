import DesignSystem
import SwiftUI
import TodoCore

enum ComposerField: Hashable { case main }

/// 메인 목록: 종이 같은 목록 + 하단 유리 입력 바 (PLAN 3.3).
/// 줄을 끌어 순서를 바꾸고, 섹션(연한 배경색 카드)으로 묶는다. 순서와 섹션은 이 기기에만 저장한다.
struct TodoListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var showsViewMenu: Bool

    @FocusState private var focus: ComposerField?
    @State private var selection: String?
    @State private var editingId: String?

    var body: some View {
        @Bindable var model = model
        let rows = model.rows
        // 줄에서 `model.layout`을 직접 읽으면 안 된다: 끌어 놓는 순간 배치가 바뀌면서 그 줄만 따로 다시 그려져
        // List가 옮긴 줄을 제자리로 되돌린다. 섹션 목록은 여기서 값으로 받아 줄에 넘긴다.
        let sections = model.layout.sections
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(rows) { row in
                    rowView(row, sections: sections)
                        .padding(.leading, row.sectionId == nil ? 0 : SectionCardBackground.contentInset)
                        .listRowBackground(
                            row.tint.map {
                                SectionCardBackground(tint: $0, isFirst: row.isHeader, isLast: row.isLastInSection)
                            }
                        )
                        .listRowSeparator(row.sectionId == nil ? .automatic : .hidden)
                }
                .onMove { model.moveRows(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .onChange(of: model.editingSectionId) { _, id in
                // 새 섹션은 목록 맨 아래에 생긴다 → 보이게 내려 준다.
                guard let id, let header = model.rows.first(where: { $0.isHeader && $0.sectionId == id }) else { return }
                withAnimation { proxy.scrollTo(header.id, anchor: .center) }
            }
        }
        .overlay {
            if rows.isEmpty, !model.isRefreshing { AllDoneView() }
        }
        .refreshable { await model.refresh() }
        .navigationTitle(model.currentSummary?.name ?? "")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar { toolbar }
        .safeAreaBar(edge: .bottom) { bottomBar }
        .onKeyPress(.space) {
            guard focus == nil, editingId == nil, let id = selection,
                let item = model.items.first(where: { $0.id == id })
            else { return .ignored }
            model.toggle(item)
            return .handled
        }
        .onKeyPress(.delete) { trashSelection() }
        #if os(macOS)
            .onDeleteCommand { _ = trashSelection() }
        #endif
        .onChange(of: model.composerFocusRequest) { focus = .main }
        .task {
            // 앱을 열면 커서가 이미 입력 바에 있다 (PLAN 2.1-3).
            focus = .main
        }
        .animation(reduceMotion ? Motion.reduced : Motion.check, value: rows.map(\.id))
    }

    @ViewBuilder func rowView(_ row: LayoutRow, sections: [LayoutSection]) -> some View {
        switch row.kind {
        case .item(let item):
            TodoRow(
                item: item, isWritable: model.isWritable, showsDue: model.currentView?.datePropertyId != nil,
                isEditing: editingBinding(item.id),
                onToggle: { model.toggle(item) },
                onRename: { model.rename(item, to: $0) },
                onExplainReadOnly: { model.explainReadOnly() })
                .tag(item.id)
                .swipeActions(edge: .leading) {
                    if model.isWritable {
                        Button { model.toggle(item) } label: {
                            Label(item.isDone ? "Uncheck" : "Check", systemImage: item.isDone ? "circle" : "checkmark")
                        }
                        .tint(.memoAccent)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { model.trash(item) } label: { Label("Delete", systemImage: "trash") }
                }
                .contextMenu { contextMenu(item, sectionId: row.sectionId, sections: sections) }
        case .header(let title, let count):
            // 머리도 끌 수 있다(섹션이 통째로 옮겨 간다). `moveDisabled`로 막으면 그 자리에 항목을 놓을 수도 없게 된다.
            if let sectionId = row.sectionId, let tint = row.tint {
                SectionHeaderRow(
                    title: title, count: count, tint: tint, isEditing: sectionEditingBinding(sectionId),
                    onRename: { model.renameSection(sectionId, to: $0) }
                ) {
                    sectionMenu(sectionId, tint: tint, sections: sections)
                }
                // iOS에서는 머리에 문맥 메뉴를 달지 않는다: 길게 눌러 끄는 동작과 겹쳐, 끌다가 메뉴 항목이 골라질 수 있다.
                // 같은 메뉴가 ••• 단추에 있다.
                #if os(macOS)
                    .contextMenu { sectionMenu(sectionId, tint: tint, sections: sections) }
                #endif
                .selectionDisabled()
            }
        }
    }

    /// 섹션 머리의 ••• 메뉴와 문맥 메뉴.
    @ViewBuilder func sectionMenu(_ id: UUID, tint: SectionTint, sections: [LayoutSection]) -> some View {
        Button { model.editingSectionId = id } label: { Label("Rename", systemImage: "pencil") }
        Picker(selection: Binding(get: { tint }, set: { model.setTint($0, forSection: id) })) {
            ForEach(SectionTint.allCases, id: \.self) { Text($0.name).tag($0) }
        } label: {
            Label("Color", systemImage: "paintpalette")
        }
        .pickerStyle(.menu)
        Divider()
        Button { model.moveSection(id, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
            .disabled(sections.first?.id == id)
        Button { model.moveSection(id, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
            .disabled(sections.last?.id == id)
        Divider()
        Button(role: .destructive) { model.removeSection(id) } label: { Label("Delete Section", systemImage: "trash") }
    }

    /// 툴바의 정리 메뉴: 새 섹션, Notion 순서로 되돌리기.
    var organizeMenu: some View {
        Menu {
            Button { model.addSection() } label: { Label("New Section", systemImage: "plus") }
            Button { model.resetOrder() } label: { Label("Reset to Notion Order", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canResetOrder)
        } label: {
            Label("Organize", systemImage: "rectangle.grid.1x2")
        }
    }

    var bottomBar: some View {
        @Bindable var model = model
        return VStack(spacing: Spacing.xs) {
            if let undo = model.undo {
                UndoToast(message: undo.message) { undo.perform() }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            if let error = model.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.m)
                    .onTapGesture { model.lastError = nil }
            }
            GlassComposer(text: $model.composerText, focus: $focus, field: .main) { model.add() }
        }
        .animation(.smooth, value: model.undo?.id)
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        if showsViewMenu {
            ToolbarItem(placement: .principal) { ViewPickerMenu() }
        }
        if model.isOffline {
            ToolbarItem {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.secondary)
                    .help(Text("Offline — changes will sync later"))
                    .accessibilityLabel(Text("Offline"))
            }
        }
        #if os(iOS)
            if showsViewMenu {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showsSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
        #else
            ToolbarItem {
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        #endif
        ToolbarItem { organizeMenu }
    }

    @ViewBuilder func contextMenu(_ item: TodoItem, sectionId: UUID?, sections: [LayoutSection]) -> some View {
        if model.isWritable {
            Button { model.toggle(item) } label: {
                Label(item.isDone ? "Uncheck" : "Check", systemImage: item.isDone ? "circle" : "checkmark.circle")
            }
        }
        Button { editingId = item.id } label: { Label("Edit", systemImage: "pencil") }
        if !sections.isEmpty {
            Menu {
                ForEach(sections) { section in
                    Button { model.move(item, toSection: section.id) } label: {
                        if section.id == sectionId {
                            Label(section.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(verbatim: section.displayTitle)
                        }
                    }
                    .disabled(section.id == sectionId)
                }
                if sectionId != nil {
                    Divider()
                    Button("No Section") { model.move(item, toSection: nil) }
                }
            } label: {
                Label("Move to Section", systemImage: "rectangle.grid.1x2")
            }
        }
        if let url = item.url.flatMap(URL.init(string:)) {
            Button { openURL(url) } label: { Label("Open in Notion", systemImage: "arrow.up.forward.app") }
        }
        Button {
            #if os(iOS)
                UIPasteboard.general.string = item.title
            #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.title, forType: .string)
            #endif
        } label: { Label("Copy", systemImage: "doc.on.doc") }
        Divider()
        Button(role: .destructive) { model.trash(item) } label: { Label("Delete", systemImage: "trash") }
    }

    func trashSelection() -> KeyPress.Result {
        guard focus == nil, editingId == nil, let id = selection,
            let item = model.items.first(where: { $0.id == id })
        else { return .ignored }
        model.trash(item)
        return .handled
    }

    func editingBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { editingId == id }, set: { editingId = $0 ? id : nil })
    }

    func sectionEditingBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { model.editingSectionId == id },
            set: { editing in
                if editing { model.editingSectionId = id } else if model.editingSectionId == id { model.editingSectionId = nil }
            })
    }
}

extension LayoutSection {
    /// 이름을 적지 않은 섹션은 "새 섹션"으로 보인다.
    var displayTitle: String { Self.displayTitle(title) }
    static func displayTitle(_ title: String) -> String { title.isEmpty ? String(localized: "New Section") : title }
}

extension SectionTint {
    var name: LocalizedStringKey {
        switch self {
        case .yellow: "Yellow"
        case .blue: "Blue"
        case .green: "Green"
        case .pink: "Pink"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }
}

/// 섹션 머리: 색 점 + 레이블 + 담긴 개수 + ••• 메뉴. 레이블을 누르면 그 자리에서 고친다.
/// 빈 섹션이면 아래에 끌어다 놓으라는 안내를 함께 보여 준다 (머리 줄이 놓을 자리를 겸한다).
struct SectionHeaderRow<MenuContent: View>: View {
    var title: String
    var count: Int
    var tint: SectionTint
    @Binding var isEditing: Bool
    var onRename: (String) -> Void
    @ViewBuilder var menu: () -> MenuContent

    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    static var dotSize: CGFloat { 8 }

    static var emptyHint: LocalizedStringKey {
        #if os(iOS)
            "Touch and hold a memo, then drag it here."
        #else
            "Drag memos here."
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleLine
            if count == 0 {
                Text(Self.emptyHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    // 색 점 너비 + 간격만큼 들여서 레이블과 줄을 맞춘다.
                    .padding(.leading, Self.dotSize + Spacing.xs)
                    .padding(.bottom, Spacing.s)
            }
        }
        // 카드 위쪽 여백만큼 내려서 색 배경 한가운데에 오게 한다.
        .padding(.top, SectionCardBackground.topGap)
    }

    var titleLine: some View {
        HStack(spacing: Spacing.xs) {
            Circle()
                .fill(tint.color)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .accessibilityHidden(true)
            if isEditing {
                TextField("Section name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .focused($editorFocused)
                    .onSubmit(commit)
                    .onAppear {
                        draft = title
                        editorFocused = true
                    }
                    .onChange(of: editorFocused) { _, focused in if !focused { commit() } }
                    .accessibilityIdentifier("section-name")
            } else {
                Text(verbatim: LayoutSection.displayTitle(title))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .contentShape(.rect)
                    .onTapGesture { isEditing = true }
                    .accessibilityAddTraits(.isHeader)
                if count > 0 {
                    Text("\(count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Section options, \(LayoutSection.displayTitle(title))"))
        }
        .frame(minHeight: Spacing.rowMinHeight)
    }

    func commit() {
        guard isEditing else { return }
        isEditing = false
        onRename(draft)
    }
}

/// iPhone 제목 자리의 뷰 전환 메뉴.
struct ViewPickerMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
            Divider()
            Button { model.showsAddDatabase = true } label: {
                Label("Add Database…", systemImage: "plus")
            }
            Button { Task { await model.refreshCatalog() } } label: {
                Label("Reload views", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.currentSummary?.databaseTitle ?? "").font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel(Text("Change view"))
        .accessibilityValue(Text(verbatim: model.currentSummary.map { "\($0.name) · \($0.databaseTitle)" } ?? ""))
    }
}

struct TodoRow: View {
    var item: TodoItem
    var isWritable: Bool
    var showsDue: Bool
    @Binding var isEditing: Bool
    var onToggle: () -> Void
    var onRename: (String) -> Void
    var onExplainReadOnly: () -> Void = {}

    @State private var draft = ""
    @FocusState private var editorFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var circle: CGFloat = Spacing.checkDiameter

    var body: some View {
        let baselineOffset = circle * 0.27
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            if isWritable {
                Button(action: onToggle) {
                    CheckCircle(isDone: item.isDone, isPending: item.isPending, diameter: circle)
                        .frame(width: max(Spacing.rowMinHeight, circle), height: max(Spacing.rowMinHeight, circle))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                #if os(iOS)
                    .hoverEffect(.highlight)  // iPad 포인터가 체크 원에 붙는다
                #endif
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + baselineOffset }
                .sensoryFeedback(.success, trigger: item.isDone) { _, done in done }
                .accessibilityLabel(item.accessibilityDescription)
                .accessibilityValue(item.accessibilityStatus)
                .accessibilityHint(Text(item.isDone ? "Marks as not done" : "Marks as done"))
                .accessibilityAddTraits(.isButton)
                .padding(.leading, -Spacing.s)
            } else {
                Button(action: onExplainReadOnly) {
                    Circle().fill(.secondary).frame(width: 6, height: 6)
                        .frame(width: max(Spacing.rowMinHeight, circle), height: Spacing.rowMinHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.leading, -Spacing.s)
                .accessibilityLabel(Text("Read only"))
            }
            if isEditing {
                TextField("Memo", text: $draft, axis: .vertical)
                    .focused($editorFocused)
                    .onSubmit(commit)
                    .onAppear {
                        draft = item.title
                        editorFocused = true
                    }
                    .onChange(of: editorFocused) { _, focused in if !focused { commit() } }
            } else {
                TodoRowContent(item: item, showsDue: showsDue)
                    .contentShape(.rect)
                    .onTapGesture { if !item.isLocalOnly { isEditing = true } }
                    .accessibilityAction(named: Text("Edit")) { isEditing = true }
            }
        }
        .frame(minHeight: Spacing.rowMinHeight)
        .animation(reduceMotion ? Motion.reduced : Motion.check, value: item.isDone)
    }

    func commit() {
        guard isEditing else { return }
        isEditing = false
        onRename(draft)
    }
}
