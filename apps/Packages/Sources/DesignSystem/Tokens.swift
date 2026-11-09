import SwiftUI

// PLAN 2.2 디자인 토큰. 앱과 위젯이 같은 값을 쓴다.

/// 8비트 RGB. 대비 검증 테스트(DesignSystemTests)가 같은 값을 읽는다.
struct RGB: Hashable, Sendable {
    var red: Int
    var green: Int
    var blue: Int

    init(_ red: Int, _ green: Int, _ blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

enum Palette {
    /// 라이트 #9A6312 / 다크 #F6B73C — 각 배경 대비 4.5:1 이상.
    static let accent = (light: RGB(0x9A, 0x63, 0x12), dark: RGB(0xF6, 0xB7, 0x3C))
    static let onAccent = (light: RGB(0xFF, 0xFF, 0xFF), dark: RGB(0x1C, 0x14, 0x05))
}

extension Color {
    /// 앰버 강조색. 체크 원 채움·주요 유리 버튼 틴트·남은 개수에만 쓴다 (화면당 한 곳).
    public static let memoAccent = Color(light: Palette.accent.light, dark: Palette.accent.dark)

    /// 체크된 원 안 체크 표시 색. 강조색 위에서 읽히는 색.
    public static let memoOnAccent = Color(light: Palette.onAccent.light, dark: Palette.onAccent.dark)

    init(light: RGB, dark: RGB) {
        #if os(iOS)
            self.init(
                uiColor: UIColor { traits in
                    let c = traits.userInterfaceStyle == .dark ? dark : light
                    return UIColor(
                        red: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255, blue: CGFloat(c.blue) / 255, alpha: 1)
                })
        #else
            self.init(
                nsColor: NSColor(name: nil) { appearance in
                    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let c = isDark ? dark : light
                    return NSColor(
                        red: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255, blue: CGFloat(c.blue) / 255, alpha: 1)
                })
        #endif
    }
}

public enum Spacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let s: CGFloat = 12
    public static let m: CGFloat = 16
    public static let l: CGFloat = 24
    /// 행 최소 높이 = 터치 영역.
    public static let rowMinHeight: CGFloat = 44
    public static let checkDiameter: CGFloat = 22
}

public enum Motion {
    /// 체크 후 목록에서 빠지기까지 — 실행 취소 구간.
    public static let removalDelay: Duration = .milliseconds(800)
    public static let check = Animation.spring(response: 0.32, dampingFraction: 0.72)
    public static let reduced = Animation.easeInOut(duration: 0.2)

    /// 뷰 밖(모델)에서 쓸 때: 동작 줄이기가 켜져 있으면 튀는 스프링 대신 짧은 페이드.
    @MainActor public static var preferred: Animation {
        #if os(iOS)
            UIAccessibility.isReduceMotionEnabled ? reduced : check
        #else
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? reduced : check
        #endif
    }
}

extension Font {
    /// 남은 개수: 둥근 서체 + 고정폭 숫자. 메모 느낌을 주는 유일한 서체 변화.
    public static func memoCount(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .rounded).weight(.semibold).monospacedDigit()
    }
}
