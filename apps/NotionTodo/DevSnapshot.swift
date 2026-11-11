#if DEBUG && os(macOS)
    import AppKit

    /// 화면을 볼 수 없을 때(잠금·원격) Mac 창 모양을 확인하는 개발용 도구.
    /// `NT_DEV_SNAPSHOT_DIR=<폴더>`로 실행하면 떠 있는 창을 1초마다 그 폴더에 PNG로 적는다.
    /// 화면 캡처가 아니라 창을 직접 그리므로 화면이 잠겨 있어도 된다 (유리 효과는 평평하게 나온다).
    @MainActor
    enum DevSnapshot {
        private static var timer: Timer?

        static func startIfRequested() {
            guard timer == nil, let path = ProcessInfo.processInfo.environment["NT_DEV_SNAPSHOT_DIR"] else { return }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { write(to: folder) }
            }
        }

        private static func write(to folder: URL) {
            // 어떤 창이 있는지도 적어 둔다 (안 보이는 창은 그리지 않는다).
            let index = NSApp.windows.map { window in
                "\(type(of: window)) | \(window.title) | visible=\(window.isVisible) | \(Int(window.frame.width))x\(Int(window.frame.height))"
            }
            try? index.joined(separator: "\n").write(to: folder.appending(path: "windows.txt"), atomically: true, encoding: .utf8)
            for window in NSApp.windows where window.isVisible {
                // 제목 막대·툴바까지 담으려고 내용 뷰의 위(테마 프레임)를 그린다.
                guard let view = window.contentView?.superview ?? window.contentView, view.bounds.width > 1,
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else { continue }
                if let layer = view.layer, let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext {
                    // SwiftUI 목록은 레이어에 직접 그려서 `cacheDisplay`에는 안 잡힌다 → 레이어 트리를 그린다.
                    context.scaleBy(x: bitmap.size.width / view.bounds.width, y: bitmap.size.height / view.bounds.height)
                    layer.render(in: context)
                } else {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                }
                let kind = String(describing: type(of: window))
                let name = "\(kind)-\(window.title.isEmpty ? "untitled" : window.title)-\(window.windowNumber)"
                    .replacingOccurrences(of: "/", with: "-")
                try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appending(path: name + ".png"))
            }
        }
    }
#endif
