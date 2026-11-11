#if os(macOS)
    import AppKit
    import DesignSystem
    import SwiftUI
    import TodoCore

    /// 떠 있는 메모 (Mac): 다른 앱 창 위에 늘 떠 있는 반투명한 작은 창. 스티커 메모처럼 쓴다 (DECISIONS 2026-11-11).
    /// 켜고 끄기와 불투명도는 UserDefaults에 있고 설정·메뉴가 `@AppStorage`로 바꾼다. 여기서는 그 값을 따라 창을 띄우고 닫는다.
    @MainActor
    final class FloatingNote: NSObject, NSWindowDelegate {
        static let shared = FloatingNote()

        enum Key {
            static let isShown = "showsFloatingNote"
            static let opacity = "floatingNoteOpacity"
            /// 떠 있는 메모가 보여 주는 뷰. 창들이 같이 쓰는 "마지막으로 연 뷰"와 따로 기억한다.
            static let viewId = "floatingNoteViewId"
            /// 사용자가 둔 자리와 펼친 크기 (`NSStringFromRect`). 접혀 있어도 펼친 크기를 적는다.
            static let frame = "floatingNoteFrame"
            /// 머리 줄만 남기고 접었는지.
            static let isCollapsed = "floatingNoteCollapsed"
        }

        /// 포인터가 밖에 있을 때의 불투명도. 포인터를 올리거나 글을 적는 동안은 또렷하게(1) 보인다.
        static let defaultOpacity = 0.8
        static let opacityRange = 0.3...1.0
        /// 늘 보이는 창이라 다른 기기에서 바꾼 내용도 따라가야 한다. 위젯(15~60분)보다 자주, Notion 요청 한도에는 한참 못 미치게.
        static let refreshInterval: Duration = .seconds(300)
        /// 포인터를 올렸을 때, 마지막으로 받은 지 이만큼 지났으면 다시 받는다.
        static let staleAfter: TimeInterval = 60
        /// 머리 줄의 높이 = 접었을 때의 창 높이.
        static let headerHeight: CGFloat = 34
        static let minimumSize = NSSize(width: 200, height: 150)

        /// 펼쳤을 때의 창 높이. 접혀 있는 동안에도 기억해 두었다가 펼칠 때 쓴다.
        private var expandedHeight: CGFloat = 340
        /// 접고 펼치느라 창 높이를 바꾸는 중 (이때의 크기 변화는 사용자가 정한 크기가 아니다).
        private var isChangingHeight = false
        private var lastCollapseToggle = Date.distantPast

        private var panel: NSPanel?
        private var model: AppModel?
        private var refreshLoop: Task<Void, Never>?
        private var observations: [NSKeyValueObservation] = []

        /// 앱이 뜰 때 한 번 부른다. 설정대로 띄우고, 그 뒤로 설정이 바뀔 때마다 맞춘다.
        func start() {
            guard observations.isEmpty else { return }
            let defaults = UserDefaults.standard
            observations = [
                defaults.observe(\.showsFloatingNote) { _, _ in Task { @MainActor in FloatingNote.shared.sync() } },
                defaults.observe(\.floatingNoteOpacity) { _, _ in Task { @MainActor in FloatingNote.shared.updateAlpha() } },
            ]
            sync()
        }

        private func sync() {
            if UserDefaults.standard.bool(forKey: Key.isShown) { show() } else { hide() }
        }

        // MARK: 띄우기·닫기

        private func show() {
            guard panel == nil else { return }
            let model = AppModel(ownViewKey: Key.viewId)
            let panel = NotePanel(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 340),
                // nonactivatingPanel: 메모를 눌러도 쓰던 앱이 뒤로 가지 않는다.
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered, defer: true)
            panel.title = String(localized: "Floating Note")
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                panel.standardWindowButton(button)?.isHidden = true
            }
            panel.level = .floating
            panel.isFloatingPanel = true
            // 모든 데스크탑과 전체 화면 앱 위에도 보인다.
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // 패널은 기본이 "앱이 뒤로 가면 숨는다"이다. 이 창은 그때가 쓸 때다.
            panel.hidesOnDeactivate = false
            // 체크만 할 때는 키 입력을 가져오지 않는다. 입력란을 누를 때만 가져온다.
            panel.becomesKeyOnlyIfNeeded = true
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.isRestorable = false
            panel.isExcludedFromWindowsMenu = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.contentMinSize = Self.minimumSize
            // 제목 막대를 두 번 클릭하면 시스템은 창을 확대하거나 최소화한다. 이 창에서는 스티커처럼 접는다.
            panel.onTitleBarDoubleClick = { [weak self] in self?.toggleCollapsed() }
            panel.delegate = self

            // 창이 키 창이 아닐 때도(거의 늘 그렇다) 뒤가 비치는 재질로 남게 `state`를 고정한다.
            // 재질은 메뉴의 것: 글자를 올리게 만든 재질이라 밝은 문서 위에서도 읽힌다 (hudWindow·popover는 더 밝아진다).
            let backdrop = NoteBackdrop()
            backdrop.material = .menu
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            backdrop.onHover = { [weak self] inside in self?.pointerMoved(inside: inside) }
            let host = NoteHostingView(rootView: FloatingNoteView().environment(model).tint(Color.memoAccent))
            host.translatesAutoresizingMaskIntoConstraints = false
            // 창 크기는 여기서 정한다. 내용이 창 크기를 붙잡으면 접을 때(내용이 바뀌기 전에 창이 먼저 줄어든다) 부딪힌다.
            host.sizingOptions = []
            backdrop.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
                host.topAnchor.constraint(equalTo: backdrop.topAnchor),
                host.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            ])
            panel.contentView = backdrop

            place(panel)
            expandedHeight = panel.frame.height

            self.panel = panel
            self.model = model
            applyCollapse(animated: false)
            updateAlpha(animated: false)
            // 앱을 앞으로 가져오지 않고 띄운다.
            panel.orderFrontRegardless()

            Task { await model.start() }
            refreshLoop = Task { [weak self] in
                while true {
                    try? await Task.sleep(for: FloatingNote.refreshInterval)
                    guard !Task.isCancelled, let self else { return }
                    self.updateAlpha()
                    // 화면이 잠겼거나 가려져 안 보이는 동안은 받지 않는다.
                    if self.panel?.occlusionState.contains(.visible) == true { await self.model?.refresh() }
                }
            }
        }

        private func hide() {
            guard let panel else { return }
            release()
            panel.close()
        }

        /// 사용자가 둔 자리와 크기로. 처음이거나 그 자리가 지금 화면 밖이면(모니터를 뗐다) 쓰던 화면의 오른쪽 위로.
        /// AppKit의 자리 자동 저장은 쓰지 않는다: 저장한 화면과 창이 지금 있는 화면이 다르면 자리를 비례로 옮겨 버려서,
        /// 다른 모니터에 둔 메모가 다시 켤 때마다 엉뚱한 곳에 뜬다.
        private func place(_ panel: NSPanel) {
            if let saved = UserDefaults.standard.string(forKey: Key.frame) {
                let frame = NSRectFromString(saved)
                // 잡고 끌 수 있는 머리 부분이 어느 화면에든 보여야 한다.
                let grip = NSRect(
                    x: frame.minX, y: frame.maxY - Self.headerHeight, width: frame.width, height: Self.headerHeight)
                let isReachable = NSScreen.screens.contains { screen in
                    let shown = screen.visibleFrame.intersection(grip)
                    return shown.width >= 80 && shown.height >= 20
                }
                if isReachable {
                    panel.setFrame(frame, display: false)
                    return
                }
            }
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 24, y: screen.maxY - 24))
            }
        }

        /// 왼쪽 위 자리와 펼친 크기를 적는다 (접혀 있어도).
        private func rememberFrame() {
            guard let panel else { return }
            let frame = panel.frame
            let expanded = NSRect(x: frame.minX, y: frame.maxY - expandedHeight, width: frame.width, height: expandedHeight)
            UserDefaults.standard.set(NSStringFromRect(expanded), forKey: Key.frame)
        }

        // MARK: 접기

        var isCollapsed: Bool { UserDefaults.standard.bool(forKey: Key.isCollapsed) }

        /// 머리 줄만 남기고 접거나 다시 펼친다 (스티커의 접기). 머리를 두 번 클릭하거나 머리의 단추·••• 메뉴로 부른다.
        func toggleCollapsed() {
            // 두 번 클릭 한 번이 제목 막대(AppKit)와 머리 줄(SwiftUI) 양쪽에서 올 수 있다 → 한 번만 받는다.
            guard Date.now.timeIntervalSince(lastCollapseToggle) > 0.3 else { return }
            lastCollapseToggle = .now
            UserDefaults.standard.set(!isCollapsed, forKey: Key.isCollapsed)
            applyCollapse(animated: true)
        }

        /// 창 높이를 접힌 상태에 맞춘다. 위쪽 가장자리는 제자리에 두고 아래로 접고 편다.
        private func applyCollapse(animated: Bool) {
            guard let panel else { return }
            let collapsed = isCollapsed
            var frame = panel.frame
            let top = frame.maxY
            frame.size.height = collapsed ? Self.headerHeight : max(expandedHeight, Self.minimumSize.height)
            frame.origin.y = top - frame.height
            // 화면 아래쪽에 접어 둔 메모를 펼치면 아래가 화면 밖으로 나간다 → 위로 올려 다 보이게 한다.
            if !collapsed, let visible = panel.screen?.visibleFrame, frame.minY < visible.minY {
                frame.origin.y = min(visible.minY, visible.maxY - frame.height)
            }
            // 접힌 동안에는 너비만 바꿀 수 있다.
            panel.contentMinSize = collapsed ? NSSize(width: Self.minimumSize.width, height: Self.headerHeight) : Self.minimumSize
            panel.contentMaxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude, height: collapsed ? Self.headerHeight : .greatestFiniteMagnitude)
            guard frame != panel.frame else { return }
            isChangingHeight = true
            if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    panel.animator().setFrame(frame, display: true)
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        self?.isChangingHeight = false
                        self?.rememberFrame()
                    }
                }
            } else {
                panel.setFrame(frame, display: true)
                isChangingHeight = false
                rememberFrame()
            }
        }

        /// 창과 모델을 놓는다 (꺼 두면 메모리를 쓰지 않는다).
        private func release() {
            refreshLoop?.cancel()
            refreshLoop = nil
            panel?.delegate = nil
            panel = nil
            model = nil
        }

        // MARK: 불투명도

        private func pointerMoved(inside: Bool) {
            updateAlpha()
            guard inside, let model, !model.isRefreshing,
                Date.now.timeIntervalSince(model.lastFetchedAt ?? .distantPast) > Self.staleAfter
            else { return }
            Task { await model.refresh() }
        }

        private func updateAlpha(animated: Bool = true) {
            guard let panel else { return }
            let defaults = UserDefaults.standard
            let stored = defaults.object(forKey: Key.opacity) == nil ? Self.defaultOpacity : defaults.double(forKey: Key.opacity)
            // 손쉬운 사용의 "투명도 줄이기"를 켠 사람에게는 비치게 하지 않는다 (바탕 재질은 시스템이 알아서 불투명하게 한다).
            let idle = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                ? 1 : min(max(stored, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
            // 나간 알림을 놓쳐도 또렷한 채로 남지 않게, 받은 값 대신 포인터 자리를 직접 본다.
            let isInUse = panel.isKeyWindow || panel.frame.contains(NSEvent.mouseLocation)
            let target = isInUse ? 1 : idle
            guard abs(panel.alphaValue - target) > 0.001 else { return }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    panel.animator().alphaValue = target
                }
            } else {
                panel.alphaValue = target
            }
        }

        // MARK: NSWindowDelegate

        func windowDidBecomeKey(_ notification: Notification) { updateAlpha() }
        func windowDidResignKey(_ notification: Notification) { updateAlpha() }
        func windowDidMove(_ notification: Notification) {
            if !isChangingHeight { rememberFrame() }
        }

        func windowDidResize(_ notification: Notification) {
            // 접고 펼치는 중의 크기는 적지 않는다. 사용자가 바꾼 크기만 펼친 크기로 기억한다.
            guard let panel, !isChangingHeight else { return }
            if !isCollapsed { expandedHeight = panel.frame.height }
            rememberFrame()
        }

        func windowWillClose(_ notification: Notification) {
            // ⌘W로 닫았다 → 설정도 끈다. 다시 켜는 곳은 설정·보기 메뉴·메뉴 막대 창.
            guard panel != nil else { return }
            release()
            UserDefaults.standard.set(false, forKey: Key.isShown)
        }

        // MARK: 앱 창 열기

        /// 앱 창을 앞으로 가져와 이 주소를 연다. 떠 있는 메모는 SwiftUI 장면 밖이라 `openWindow`를 쓸 수 없다.
        static func openApp(_ url: URL) {
            NSWorkspace.shared.open(
                [url], withApplicationAt: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    extension UserDefaults {
        // KVO로 지켜보려면 키와 이름이 같은 속성이 있어야 한다.
        @objc fileprivate dynamic var showsFloatingNote: Bool { bool(forKey: FloatingNote.Key.isShown) }
        @objc fileprivate dynamic var floatingNoteOpacity: Double { double(forKey: FloatingNote.Key.opacity) }
    }

    /// 입력란에 적을 수 있게 키 창은 되지만 주 창은 되지 않는다 (메뉴와 단축키의 대상은 앱 창 그대로).
    private final class NotePanel: NSPanel {
        var onTitleBarDoubleClick: (() -> Void)?

        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }

        // 제목 막대 두 번 클릭은 시스템 설정에 따라 확대나 최소화로 온다. 어느 쪽이든 창을 키우거나 Dock으로 보내지 않는다.
        override func performZoom(_ sender: Any?) { onTitleBarDoubleClick?() }
        override func zoom(_ sender: Any?) { onTitleBarDoubleClick?() }
        override func performMiniaturize(_ sender: Any?) { onTitleBarDoubleClick?() }
        override func miniaturize(_ sender: Any?) { onTitleBarDoubleClick?() }
    }

    /// 뒤가 비치는 바탕. 포인터가 들어오고 나가는 것을 알린다 (앱이 앞에 있지 않아도).
    private final class NoteBackdrop: NSVisualEffectView {
        var onHover: ((Bool) -> Void)?
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }

    /// 창이 키 창이 아니어도 첫 클릭이 그대로 단추에 닿게 한다 (체크하려고 두 번 누르지 않게).
    private final class NoteHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
#endif
