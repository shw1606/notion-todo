import SwiftUI

// PLAN 2.2 디자인 토큰. 앱과 위젯이 같은 값을 쓴다.

extension Color {
    /// 앰버 강조색. 체크 원 채움·주요 유리 버튼 틴트·남은 개수에만 쓴다 (화면당 한 곳).
    /// 라이트 #9A6312 / 다크 #F6B73C — 각 배경 대비 4.5:1 이상 (DesignSystemTests에서 검증).
    public static let memoAccent = Color(light: (0x9A, 0x63, 0x12), dark: (0xF6, 0xB7, 0x3C))

    /// 체크된 원 안 체크 표시 색. 강조색 위에서 읽히는 색.
    public static let memoOnAccent = Color(light: (0xFF, 0xFF, 0xFF), dark: (0x1C, 0x14, 0x05))

    init(light: (Int, Int, Int), dark: (Int, Int, Int)) {
        #if os(iOS)
            self.init(
                uiColor: UIColor { traits in
                    let c = traits.userInterfaceStyle == .dark ? dark : light
                    return UIColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
                })
        #else
            self.init(
                nsColor: NSColor(name: nil) { appearance in
                    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let c = isDark ? dark : light
                    return NSColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
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
}

extension Font {
    /// 남은 개수: 둥근 서체 + 고정폭 숫자. 메모 느낌을 주는 유일한 서체 변화.
    public static func memoCount(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .rounded).weight(.semibold).monospacedDigit()
    }
}
