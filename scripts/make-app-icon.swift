// 앱 아이콘 생성: 따뜻한 메모지 위 앰버 체크 원. `swift scripts/make-app-icon.swift <출력 폴더>`
import AppKit

func render(size: CGFloat, dark: Bool, tinted: Bool) -> Data {
    // 화면 배율과 무관하게 정확한 픽셀 크기로 그린다.
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    // 배경: 종이 (다크·틴트 변형은 시스템 규칙대로 배경 없음/어두운 배경)
    if tinted {
        NSColor.black.setFill(); ctx.fill(rect)
    } else if dark {
        NSColor(calibratedRed: 0.10, green: 0.09, blue: 0.08, alpha: 1).setFill(); ctx.fill(rect)
    } else {
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 1.00, green: 0.97, blue: 0.88, alpha: 1),
            NSColor(calibratedRed: 0.99, green: 0.91, blue: 0.70, alpha: 1),
        ])!
        gradient.draw(in: rect, angle: -90)
    }
    // 메모 줄 세 개
    let lineColor = tinted ? NSColor(white: 0.55, alpha: 1) : (dark ? NSColor(white: 1, alpha: 0.22) : NSColor(calibratedRed: 0.60, green: 0.39, blue: 0.07, alpha: 0.28))
    lineColor.setFill()
    for i in 0..<3 {
        let y = size * (0.60 - CGFloat(i) * 0.15)
        let width = size * (i == 2 ? 0.30 : 0.42)
        NSBezierPath(roundedRect: CGRect(x: size * 0.46, y: y, width: width, height: size * 0.055), xRadius: size * 0.0275, yRadius: size * 0.0275).fill()
    }
    // 체크 원
    let amber = tinted ? NSColor(white: 1, alpha: 1) : (dark ? NSColor(calibratedRed: 0.965, green: 0.718, blue: 0.235, alpha: 1) : NSColor(calibratedRed: 0.604, green: 0.388, blue: 0.071, alpha: 1))
    let circle = CGRect(x: size * 0.14, y: size * 0.38, width: size * 0.26, height: size * 0.26)
    amber.setFill(); NSBezierPath(ovalIn: circle).fill()
    let check = NSBezierPath()
    check.move(to: CGPoint(x: circle.minX + circle.width * 0.27, y: circle.midY))
    check.line(to: CGPoint(x: circle.minX + circle.width * 0.44, y: circle.minY + circle.height * 0.32))
    check.line(to: CGPoint(x: circle.minX + circle.width * 0.75, y: circle.minY + circle.height * 0.70))
    check.lineWidth = size * 0.028; check.lineCapStyle = .round; check.lineJoinStyle = .round
    (tinted ? NSColor.black : (dark ? NSColor(calibratedRed: 0.11, green: 0.08, blue: 0.02, alpha: 1) : .white)).setStroke(); check.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, dark, tinted) in [("icon-light", false, false), ("icon-dark", true, false), ("icon-tinted", false, true)] {
    try! render(size: 1024, dark: dark, tinted: tinted).write(to: out.appendingPathComponent("\(name).png"))
}
// macOS용 크기
for s in [16, 32, 64, 128, 256, 512, 1024] {
    try! render(size: CGFloat(s), dark: false, tinted: false).write(to: out.appendingPathComponent("mac-\(s).png"))
}
