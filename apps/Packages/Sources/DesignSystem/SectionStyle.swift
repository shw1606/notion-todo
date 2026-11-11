import SwiftUI
import TodoCore

// 로컬 섹션의 모양 (DECISIONS 2026-11-11). 섹션은 연한 배경색 카드 한 장으로 구분한다.

extension SectionTint {
    /// 섹션 머리의 점과 배경에 쓰는 색. 라이트·다크에 맞춰 바뀌는 시스템 색이다.
    public var color: Color {
        switch self {
        case .yellow: .yellow
        case .blue: .blue
        case .green: .green
        case .pink: .pink
        case .purple: .purple
        case .gray: .gray
        }
    }
}

/// 섹션에 속한 줄의 배경. 줄마다 깔면 섹션 전체가 연한 색 카드 한 장으로 이어진다.
/// 첫 줄(머리)은 위쪽, 마지막 줄은 아래쪽 모서리를 둥글린다.
public struct SectionCardBackground: View {
    var tint: SectionTint
    var isFirst: Bool
    var isLast: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// 카드 위쪽 여백 = 앞 묶음과의 간격. 머리 줄은 이만큼 내용을 내려 그린다.
    public static let topGap: CGFloat = Spacing.xs
    /// 카드 좌우 여백 (줄 전체 폭에서 이만큼 들어온다).
    static let sideInset: CGFloat = Spacing.xs
    /// 카드 안 내용을 더 들여 쓸 폭. Mac 목록은 줄 여백이 카드 여백과 같아서 그대로 두면 체크 원이 카드 끝에 붙는다.
    /// iPhone·iPad는 줄 여백이 넉넉해 들여 쓰지 않는다.
    public static var contentInset: CGFloat {
        #if os(macOS)
            Spacing.xs
        #else
            0
        #endif
    }
    static let radius: CGFloat = 12

    public init(tint: SectionTint, isFirst: Bool, isLast: Bool) {
        self.tint = tint
        self.isFirst = isFirst
        self.isLast = isLast
    }

    /// 글자 대비를 해치지 않을 만큼만 연하게. 다크에서는 같은 농도가 더 옅어 보여 조금 올린다.
    static func opacity(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.22 : 0.14 }

    public var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? Self.radius : 0, bottomLeadingRadius: isLast ? Self.radius : 0,
            bottomTrailingRadius: isLast ? Self.radius : 0, topTrailingRadius: isFirst ? Self.radius : 0,
            style: .continuous
        )
        .fill(tint.color.opacity(Self.opacity(colorScheme)))
        .padding(.horizontal, Self.sideInset)
        .padding(.top, isFirst ? Self.topGap : 0)
    }
}
