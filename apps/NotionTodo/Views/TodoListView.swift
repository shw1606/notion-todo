import DesignSystem
import SwiftUI
import TodoCore

enum ComposerField: Hashable { case main }

/// 메인 목록: 종이 같은 목록 + 하단 유리 입력 바 (PLAN 3.3).
struct TodoListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    var showsViewMenu: Bool

    @FocusState private var focus: ComposerField?
    @State private var selection: String?
    @State private var editingId: String?

    var body: some View {
        @Bindable var model = model
        List(selection: $selection) {
            ForEach(model.displayItems) { item in
                TodoRow(
                    item: item, isWritable: model.isWritable, showsDue: model.currentView?.datePropertyId != nil,
                    isEditing: editingBinding(item.id),
                    onToggle: { model.toggle(item) },
                    onRename: { model.rename(item, to: $0) })
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
                    .contextMenu { contextMenu(item) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.displayItems.isEmpty, !model.isRefreshing { AllDoneView() }
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
            // 앱을 열면 커서가 이미 입력 바에 있다 (PLAN 2.1-3). iPhone에서만 — 키보드가 화면을 가리지 않는 곳은 바로.
            focus = .main
        }
        .animation(Motion.check, value: model.displayItems.map(\.id))
    }

    var bottomBar: some View {
        @Bindable var model = model
        return VStack(spacing: Spacing.xs) {
            if let undo = model.undo {
                UndoToast(message: undo.message) { undo.perform() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
    }

    @ViewBuilder func contextMenu(_ item: TodoItem) -> some View {
        if model.isWritable {
            Button { model.toggle(item) } label: {
                Label(item.isDone ? "Uncheck" : "Check", systemImage: item.isDone ? "circle" : "checkmark.circle")
            }
        }
        Button { editingId = item.id } label: { Label("Edit", systemImage: "pencil") }
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
    }
}

struct TodoRow: View {
    var item: TodoItem
    var isWritable: Bool
    var showsDue: Bool
    @Binding var isEditing: Bool
    var onToggle: () -> Void
    var onRename: (String) -> Void

    @State private var draft = ""
    @FocusState private var editorFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var circle: CGFloat = Spacing.checkDiameter

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            if isWritable {
                Button(action: onToggle) {
                    CheckCircle(isDone: item.isDone, isPending: item.isPending, diameter: circle)
                        .frame(width: max(Spacing.rowMinHeight, circle), height: max(Spacing.rowMinHeight, circle))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + circle * 0.27 }
                .sensoryFeedback(.success, trigger: item.isDone) { _, done in done }
                .accessibilityLabel(item.accessibilityDescription)
                .accessibilityHint(Text(item.isDone ? "Marks as not done" : "Marks as done"))
                .accessibilityAddTraits(.isButton)
                .padding(.leading, -Spacing.s)
            } else {
                Circle().fill(.secondary).frame(width: 6, height: 6)
                    .frame(width: Spacing.checkDiameter)
                    .accessibilityHidden(true)
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
