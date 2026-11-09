import XCTest

/// 핵심 흐름 3개 (PLAN 6.1): 추가 → 체크 → 실행 취소 / 뷰 전환 / 오프라인 추가 후 복구. iPhone·Mac 공용.
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

    var composer: XCUIElement { app.descendants(matching: .any).matching(identifier: "composer").firstMatch }

    func testAddCheckUndoDelete() throws {
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "입력 바가 보여야 한다")
        let title = "UI 테스트 \(Int(Date().timeIntervalSince1970))"
        press(composer)
        composer.typeText(title + "\n")

        let row = app.staticTexts[title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "추가한 메모가 목록에 보여야 한다")

        // 체크 → 0.8초 뒤 "할 일" 뷰에서 빠진다
        let check = checkButton(title)
        XCTAssertTrue(check.waitForExistence(timeout: 10))
        press(check)
        XCTAssertTrue(waitForDisappearance(row, timeout: 5), "체크한 메모는 미완료 뷰에서 빠져야 한다")

        // 실행 취소 → 다시 보인다
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        press(undo)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "실행 취소하면 다시 보여야 한다")

        try deleteAndWait(row)
    }

    /// 다른 뷰를 고르면 제목이 바뀌고, 원래 뷰로 돌아올 수 있다.
    func testSwitchViewAndBack() throws {
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        #if os(macOS)
            // 사이드바에서 다른 뷰를 누른다. 창 제목 = 뷰 이름.
            // 뷰 이름은 글자의 value에 있다 (DB 이름 구역 머리는 label). 셀 좌표는 한 행씩 어긋나게 보고될 때가 있어 글자를 누른다.
            let window = app.windows.firstMatch
            let original = window.title
            let texts = app.outlines.firstMatch.staticTexts
            let names = texts.matching(NSPredicate(format: "value != nil AND value != ''"))
            XCTAssertTrue(names.firstMatch.waitForExistence(timeout: 10))
            let all = names.allElementsBoundByIndex.compactMap { $0.value as? String }
            try XCTSkipUnless(all.filter { $0 == original }.count == 1, "같은 이름의 뷰가 여럿이면 돌아올 뷰를 고를 수 없다")
            let target = try XCTUnwrap(all.first { $0 != original }, "이름이 다른 뷰가 하나 이상 있어야 한다")
            texts.matching(NSPredicate(format: "value == %@", target)).firstMatch.click()
            XCTAssertTrue(wait(window, "title == %@", target, timeout: 10), "고른 뷰로 바뀌어야 한다")

            texts.matching(NSPredicate(format: "value == %@", original)).firstMatch.click()
            XCTAssertTrue(wait(window, "title == %@", original, timeout: 10), "원래 뷰로 돌아와야 한다")
        #else
            // 제목 자리 메뉴. 메뉴 버튼의 값 = "뷰 이름 · DB 이름".
            let picker = app.buttons["Change view"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 10))
            let original = try XCTUnwrap(picker.value as? String)
            picker.tap()
            let options = app.buttons.matching(NSPredicate(format: "label CONTAINS ' · '"))
            XCTAssertTrue(options.firstMatch.waitForExistence(timeout: 5), "뷰 목록이 떠야 한다")
            let target = try XCTUnwrap(
                options.allElementsBoundByIndex.first { viewName($0.label) != viewName(original) },
                "이름이 다른 뷰가 하나 이상 있어야 한다")
            let targetLabel = target.label
            target.tap()
            XCTAssertTrue(wait(picker, "value == %@", targetLabel, timeout: 10))
            XCTAssertTrue(app.navigationBars.staticTexts[viewName(targetLabel)].firstMatch.waitForExistence(timeout: 5))

            picker.tap()
            let back = app.buttons.matching(NSPredicate(format: "label == %@", original)).firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
            XCTAssertTrue(wait(picker, "value == %@", original, timeout: 10), "원래 뷰로 돌아와야 한다")
        #endif
    }

    /// 연결이 없을 때 적은 메모는 대기로 남고, 다시 연결되면 Notion에 들어간다.
    func testOfflineAddSyncsWhenBackOnline() throws {
        // setUp에서 온라인으로 한 번 열어 뷰 정의와 목록을 캐시에 둔다.
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        relaunch(offline: true)
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "오프라인이어도 캐시로 열려야 한다")
        XCTAssertTrue(app.descendants(matching: .any)["Offline"].firstMatch.waitForExistence(timeout: 10), "오프라인 표시")

        let title = "오프라인 테스트 \(Int(Date().timeIntervalSince1970))"
        press(composer)
        composer.typeText(title + "\n")
        let check = checkButton(title)
        XCTAssertTrue(check.waitForExistence(timeout: 10), "대기 중인 메모도 목록에 보여야 한다")
        XCTAssertEqual(check.value as? String, "Waiting to sync")

        relaunch(offline: false)
        let row = app.staticTexts[title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(checkButton(title), "value != %@", "Waiting to sync", timeout: 20), "다시 연결되면 Notion에 반영돼야 한다")

        try deleteAndWait(row)
    }

    // MARK: 도우미

    func relaunch(offline: Bool) {
        app.terminate()
        app.launchEnvironment["NT_DEV_OFFLINE"] = offline ? "1" : nil
        app.launch()
    }

    /// 행의 체크 버튼. 레이블 = "제목, 체크 안 됨".
    func checkButton(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    func viewName(_ label: String) -> String {
        label.components(separatedBy: " · ").first ?? label
    }

    func press(_ element: XCUIElement) {
        #if os(macOS)
            element.click()
        #else
            element.tap()
        #endif
    }

    /// 정리: 삭제(Notion 휴지통). 실행 취소 구간(4초)이 지나 휴지통 요청이 나갈 때까지 기다린다.
    func deleteAndWait(_ row: XCUIElement) throws {
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
        XCTAssertTrue(waitForDisappearance(row, timeout: 5))
        sleep(6)
    }

    func wait(_ element: XCUIElement, _ format: String, _ argument: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argument), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
