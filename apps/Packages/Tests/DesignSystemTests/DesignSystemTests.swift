import Foundation
import Testing

@testable import DesignSystem

/// PLAN 2.2: 강조색은 쓰이는 배경 위에서 WCAG 대비 4.5:1 이상.
@Suite struct ContrastTests {
    /// iOS·macOS 시스템 배경 (라이트: 기본·그룹, 다크: 기본·올린 배경).
    static let lightBackgrounds = [RGB(0xFF, 0xFF, 0xFF), RGB(0xF2, 0xF2, 0xF7)]
    static let darkBackgrounds = [RGB(0x00, 0x00, 0x00), RGB(0x1C, 0x1C, 0x1E)]

    @Test func accentIsReadableOnBackgrounds() {
        for background in Self.lightBackgrounds {
            #expect(contrast(Palette.accent.light, background) >= 4.5, "light \(background)")
        }
        for background in Self.darkBackgrounds {
            #expect(contrast(Palette.accent.dark, background) >= 4.5, "dark \(background)")
        }
    }

    @Test func checkmarkIsReadableOnAccent() {
        #expect(contrast(Palette.onAccent.light, Palette.accent.light) >= 4.5)
        #expect(contrast(Palette.onAccent.dark, Palette.accent.dark) >= 4.5)
    }

    @Test func formulaMatchesKnownValues() {
        #expect(abs(contrast(RGB(0, 0, 0), RGB(0xFF, 0xFF, 0xFF)) - 21) < 0.01)
        #expect(abs(contrast(Palette.accent.light, RGB(0xFF, 0xFF, 0xFF)) - 5.04) < 0.01)
    }

    func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    func luminance(_ color: RGB) -> Double {
        func linear(_ value: Int) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }
}

@Suite struct DueChipTests {
    let calendar = Calendar(identifier: .gregorian)

    func day(_ text: String) -> Date {
        DateComponents(calendar: calendar, year: 2026, month: 11, day: Int(text)!).date!
    }

    @Test func relativeDaysAndOverdue() throws {
        let now = day("9")
        #expect(try #require(DueChip.label("2026-11-09", now: now, calendar: calendar)).isOverdue == false)
        #expect(try #require(DueChip.label("2026-11-08", now: now, calendar: calendar)).isOverdue)
        #expect(try #require(DueChip.label("2026-11-10", now: now, calendar: calendar)).isOverdue == false)
        // 시각이 붙은 값도 날짜로 본다.
        #expect(DueChip.label("2026-11-09T21:00:00.000+09:00", now: now, calendar: calendar) != nil)
        #expect(DueChip.label("not a date", now: now, calendar: calendar) == nil)
    }
}
