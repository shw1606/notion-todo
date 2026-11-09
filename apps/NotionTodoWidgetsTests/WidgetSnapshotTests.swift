import SwiftUI
import TodoCore
import WidgetKit
import XCTest

/// 위젯 화면을 크기 × 렌더링 모드 × 라이트/다크 × 글자 크기로 렌더링해 PNG로 남긴다 (PLAN 6.1).
/// 렌더링 모드: 홈화면 기본(fullColor)·틴트/투명(accented), 잠금화면(vibrant).
/// 기준 이미지 비교 대신 "렌더링이 되는가 + 눈으로 검토할 산출물"을 만든다. 폰트·OS 차이로 CI에서 픽셀 비교는 불안정하다.
///
///     TEST_RUNNER_SNAPSHOT_DIR=/tmp/widget-snapshots xcodebuild test -scheme WidgetSnapshots ...
@MainActor
final class WidgetSnapshotTests: XCTestCase {
    struct Size {
        var name: String
        var family: WidgetFamily
        var size: CGSize
        var margin: CGFloat

        var isAccessory: Bool { [.accessoryRectangular, .accessoryInline, .accessoryCircular].contains(family) }
    }

    /// iPhone 6.3"·iPad 기준 대략값 (pt). 시스템 위젯 여백 16pt는 직접 넣는다.
    var sizes: [Size] {
        var sizes = [
            Size(name: "small", family: .systemSmall, size: CGSize(width: 170, height: 170), margin: 16),
            Size(name: "medium", family: .systemMedium, size: CGSize(width: 364, height: 170), margin: 16),
            Size(name: "large", family: .systemLarge, size: CGSize(width: 364, height: 382), margin: 16),
            Size(name: "extraLarge", family: .systemExtraLarge, size: CGSize(width: 715, height: 330), margin: 16),
            Size(name: "rectangular", family: .accessoryRectangular, size: CGSize(width: 172, height: 76), margin: 0),
            Size(name: "inline", family: .accessoryInline, size: CGSize(width: 260, height: 22), margin: 0),
        ]
        #if canImport(WidgetKit, _version: 749)
            if #available(iOS 27.0, *) {
                sizes.insert(
                    Size(name: "extraLargePortrait", family: .systemExtraLargePortrait,
                         size: CGSize(width: 330, height: 715), margin: 16), at: 4)
            }
        #endif
        return sizes
    }

    var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? NSTemporaryDirectory() + "widget-snapshots"
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let entries: [(String, TodoEntry)] = {
        var many = TodoEntry.placeholder()
        many.viewName = "할 일"
        many.items = [
            TodoItem(id: "a", title: "치약 사기", isDone: false, due: DayFormat.string(.now)),
            TodoItem(id: "b", title: "택배 반품 접수 — 편의점 택배로 보내고 송장번호 사진 찍어두기", isDone: false),
            TodoItem(id: "c", title: "엄마 생일 선물 알아보기, 예산 10만원", isDone: false, isPending: true),
            TodoItem(id: "d", title: "치과 예약", isDone: true),
        ] + (1...10).map { TodoItem(id: "x\($0)", title: "메모 \($0)", isDone: false) }
        var empty = TodoEntry.placeholder()
        empty.items = []
        var offline = TodoEntry.placeholder()
        offline.isOffline = true
        var readOnly = TodoEntry.placeholder()
        readOnly.isWritable = false
        // 완료로 거르지 않는 뷰: 체크한 항목이 취소선과 함께 아래에 남는다.
        var mixed = TodoEntry.placeholder()
        mixed.items[1].isDone = true
        mixed.items[3].isDone = true
        return [
            ("placeholder", .placeholder()), ("many", many), ("mixed", mixed), ("empty", empty), ("offline", offline),
            ("readonly", readOnly), ("signedOut", .state(.signedOut)), ("viewMissing", .state(.viewMissing)),
        ]
    }()

    func testListWidgetMatrix() throws {
        var count = 0
        for (entryName, entry) in Self.entries {
            for size in sizes {
                for scheme in [ColorScheme.light, .dark] {
                    let categories: [DynamicTypeSize] = entryName == "many" ? [.large, .accessibility2] : [.large]
                    for category in categories {
                        let name = "list-\(size.name)-\(entryName)-\(scheme == .dark ? "dark" : "light")-\(category == .large ? "default" : "ax2")"
                        try render(name, size: size, scheme: scheme, category: category) {
                            TodoListWidgetContent(entry: entry, family: size.family)
                        }
                        count += 1
                    }
                }
                // 홈화면 틴트·투명 외형: 체크 표시가 원에서 도려내져야 한다.
                if !size.isAccessory {
                    try render("list-\(size.name)-\(entryName)-tinted", size: size, scheme: .dark, category: .large,
                               mode: .accented) {
                        TodoListWidgetContent(entry: entry, family: size.family)
                    }
                    count += 1
                }
            }
        }
        XCTAssertGreaterThan(count, 100)
    }

    func testCountWidget() throws {
        for size in sizes where [.systemSmall].contains(size.family) {
            for scheme in [ColorScheme.light, .dark] {
                try render("count-\(size.name)-\(scheme == .dark ? "dark" : "light")", size: size, scheme: scheme, category: .large) {
                    CountWidgetContent(entry: .placeholder(), family: size.family)
                }
            }
        }
        let circular = Size(name: "circular", family: .accessoryCircular, size: CGSize(width: 76, height: 76), margin: 0)
        try render("count-circular", size: circular, scheme: .dark, category: .large) {
            CountWidgetContent(entry: .placeholder(), family: .accessoryCircular)
        }
    }

    func render<V: View>(
        _ name: String, size: Size, scheme: ColorScheme, category: DynamicTypeSize, mode: WidgetRenderingMode? = nil,
        @ViewBuilder _ content: () -> V
    ) throws {
        let isAccessory = size.isAccessory
        let view = content()
            .padding(size.margin)
            .frame(width: size.size.width, height: size.size.height, alignment: .topLeading)
            .background(isAccessory ? AnyShapeStyle(Color.black.gradient) : AnyShapeStyle(.background))
            .clipShape(.rect(cornerRadius: isAccessory ? 12 : 22))
            .environment(\.colorScheme, isAccessory ? .dark : scheme)
            .environment(\.dynamicTypeSize, category)
            .environment(\.widgetRenderingMode, mode ?? (isAccessory ? .vibrant : .fullColor))
            .environment(\.locale, Locale(identifier: "ko_KR"))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "\(name) 렌더링 실패")
        XCTAssertEqual(image.size.width, size.size.width, accuracy: 1)
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: outputDirectory.appending(path: "\(name).png"))
    }
}
