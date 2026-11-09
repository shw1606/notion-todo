// 앱 아이콘 생성: 노션 일러스트처럼 붓으로 그린 체크박스. 왼쪽·아래 획이 굵어(노션 로고의 블록처럼) 무게가 실리고,
// 체크는 상자 밖으로 뻗는다. `swift scripts/make-app-icon.swift <출력 폴더>`
import AppKit

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(size: Int, dark: Bool, tinted: Bool) -> Data {
    // 정확한 픽셀 크기로, 알파 채널 없이 그린다 (App Store는 투명 채널이 있는 아이콘을 받지 않는다).
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size), y: CGFloat(size))  // 이하 0…1 좌표, y는 위쪽
    // 노션의 종이색과 글자색 (다크·틴트 변형은 시스템 규칙대로 어두운 배경)
    let paper = tinted ? color(0x000000) : (dark ? color(0x191919) : color(0xF7F6F3))
    let ink = tinted ? color(0xFFFFFF) : (dark ? color(0xEDECE9) : color(0x37352F))
    ctx.setFillColor(paper); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))

    // 상자: 살짝 기울인 둥근 사각형 테. 바깥 테를 왼쪽·아래로 더 내밀어 그 쪽 획을 굵게 한다.
    ctx.saveGState()
    ctx.translateBy(x: 0.45, y: 0.45); ctx.rotate(by: -4 * .pi / 180); ctx.translateBy(x: -0.45, y: -0.45)
    let inner = CGRect(x: 0.23, y: 0.23, width: 0.45, height: 0.45)
    let outer = CGRect(x: inner.minX - 0.062, y: inner.minY - 0.062, width: inner.width + 0.098, height: inner.height + 0.098)
    ctx.addPath(CGPath(roundedRect: outer, cornerWidth: 0.115, cornerHeight: 0.115, transform: nil))
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 0.07, cornerHeight: 0.07, transform: nil))
    ctx.setFillColor(ink); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    // 체크: 짧게 내려갔다가 곡선으로 길게 올라가며 가늘어진다. 원을 촘촘히 찍어 붓 자국처럼 만든다.
    let start = CGPoint(x: 0.31, y: 0.50), elbow = CGPoint(x: 0.445, y: 0.335), end = CGPoint(x: 0.85, y: 0.84)
    let control = CGPoint(x: 0.60, y: 0.53)
    var dabs: [(CGPoint, CGFloat)] = []
    for i in 0...900 {
        let u = CGFloat(i) / 900
        if u < 0.24 {
            let k = u / 0.24
            dabs.append((CGPoint(x: start.x + (elbow.x - start.x) * k, y: start.y + (elbow.y - start.y) * k), 0.052 + 0.036 * k))
        } else {
            let k = (u - 0.24) / 0.76, m = 1 - k
            let point = CGPoint(x: m * m * elbow.x + 2 * m * k * control.x + k * k * end.x,
                                y: m * m * elbow.y + 2 * m * k * control.y + k * k * end.y)
            dabs.append((point, 0.088 - 0.062 * pow(k, 1.5)))
        }
    }
    // 상자 테와 겹치는 곳은 종이색 테두리로 먼저 끊어 체크가 위에 놓이게 한다.
    for (fill, extra) in [(paper, 0.042), (ink, 0.0)] {
        for (p, w) in dabs {
            let d = w + extra
            ctx.addEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
        }
        ctx.setFillColor(fill); ctx.fillPath()
    }
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, dark, tinted) in [("icon-light", false, false), ("icon-dark", true, false), ("icon-tinted", false, true)] {
    try! render(size: 1024, dark: dark, tinted: tinted).write(to: out.appendingPathComponent("\(name).png"))
}
// macOS용 크기
for s in [16, 32, 64, 128, 256, 512, 1024] {
    try! render(size: s, dark: false, tinted: false).write(to: out.appendingPathComponent("mac-\(s).png"))
}
