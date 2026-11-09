import XCTest

/// 핵심 흐름 (PLAN 6.1): 추가 → 체크 → 실행 취소 → 삭제. iPhone·Mac 공용.
/// 실제 Notion 테스트 DB에 쓴다. `TEST_RUNNER_NT_DEV_TOKEN`이 없으면 건너뛴다.
final class NotionTodoUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let token = ProcessInfo.processInfo.environment["NT_DEV_TOKEN"], !token.isEmpty else {
            throw XCTSkip("NT_DEV_TOKEN not set")
        }
        app = XCUIApplication()
        app.launchEnvironment["NT_DEV_TOKEN"] = token
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    func testAddCheckUndoDelete() throws {
        let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "입력 바가 보여야 한다")
        let title = "UI 테스트 \(Int(Date().timeIntervalSince1970))"
        press(composer)
        composer.typeText(title + "\n")

        let row = app.staticTexts[title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "추가한 메모가 목록에 보여야 한다")

        // 체크 → 0.8초 뒤 "할 일" 뷰에서 빠진다
        let check = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 10))
        press(check)
        XCTAssertTrue(waitForDisappearance(row, timeout: 5), "체크한 메모는 미완료 뷰에서 빠져야 한다")

        // 실행 취소 → 다시 보인다
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        press(undo)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "실행 취소하면 다시 보여야 한다")

        // 정리: 삭제 (Notion 휴지통)
        try delete(row)
        XCTAssertTrue(waitForDisappearance(row, timeout: 5))
        sleep(6)  // 실행 취소 구간이 지나 휴지통 요청이 나가도록
    }

    func press(_ element: XCUIElement) {
        #if os(macOS)
            element.click()
        #else
            element.tap()
        #endif
    }

    func delete(_ row: XCUIElement) throws {
        #if os(macOS)
            row.rightClick()
            // 메뉴 막대의 편집 → 삭제가 아니라, 화면에 뜬 문맥 메뉴의 삭제를 고른다.
            let item = app.menuItems.matching(NSPredicate(format: "title == 'Delete'")).allElementsBoundByIndex
                .first { $0.isHittable }
            try XCTUnwrap(item, "문맥 메뉴에 삭제가 있어야 한다").click()
        #else
            row.swipeLeft()
            let button = app.buttons["Delete"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.tap()
        #endif
    }

    func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
