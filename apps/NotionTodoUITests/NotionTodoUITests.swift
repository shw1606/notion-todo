import XCTest

/// 핵심 흐름 (PLAN 6.1): 추가 → 체크 → 실행 취소 / 뷰 전환 / 오프라인 추가 후 복구 / 첫 실행 연결 / DB 더하고 빼기 /
/// 순서 바꾸기와 섹션.
/// iPhone·Mac 공용. 실제 Notion 테스트 DB에 쓴다. `TEST_RUNNER_NT_DEV_TOKEN`이 없으면 건너뛴다.
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
        // 고른 DB가 없으면(새 시뮬레이터) 시작할 목록 화면이 뜬다. 이 앱이 만든 메모 DB로 시작한다.
        let start = app.buttons["Start"].firstMatch
        let deadline = Date.now.addingTimeInterval(20)
        while Date.now < deadline, !composer.exists, !start.exists { usleep(250_000) }
        if start.exists { startWithStarterDatabase() }
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

    /// 첫 실행 (PLAN 3.2): 토큰을 붙여 넣으면 이 앱이 만든 메모 DB가 골라져 있고, 시작 → 위젯 안내 → 목록.
    /// 로그인은 메모리에만 둔다 (`NT_DEV_SIGNED_OUT`). 새 DB는 만들지 않는다.
    func testTokenOnboarding() throws {
        let token = try XCTUnwrap(ProcessInfo.processInfo.environment["NT_DEV_TOKEN"])
        app.terminate()
        app.launchEnvironment["NT_DEV_SIGNED_OUT"] = "1"
        app.launch()

        // OAuth를 쓸 수 있는 빌드면 보조 버튼, 아니면 큰 버튼이다.
        let instead = app.buttons["Use a token instead"].firstMatch
        let primary = app.buttons["Connect with a token"].firstMatch
        XCTAssertTrue(instead.waitForExistence(timeout: 10) || primary.exists, "첫 화면에 토큰 연결 버튼이 있어야 한다")
        attachScreenshot("1 welcome")
        press(instead.exists ? instead : primary)

        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        attachScreenshot("2 token")
        press(field)
        field.typeText(token)
        press(app.buttons["Connect"].firstMatch)

        startWithStarterDatabase(screenshots: true)
        attachScreenshot("5 list")
    }

    /// "DB 추가"로 고른 DB만 목록에 생기고, 설정에서 빼면 원래 DB로 돌아온다.
    /// 테스트 워크스페이스에 메모 DB 말고 체크할 칸이 있는 DB가 하나 더 있어야 한다.
    func testAddAndRemoveDatabase() throws {
        #if os(iOS)
            XCTAssertTrue(composer.waitForExistence(timeout: 20))
            let picker = app.buttons["Change view"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 10))
            let original = try XCTUnwrap(picker.value as? String)
            let originalDatabase = try XCTUnwrap(original.components(separatedBy: " · ").last)
            picker.tap()
            app.buttons["Add Database…"].firstMatch.tap()

            // 이미 고른 메모 DB는 목록에 없다.
            let add = app.buttons["Add"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 10), "DB 추가 화면이 뜬다")
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: add)
            // DB 줄의 레이블 = "DB 이름, 체크하면 바뀌는 것".
            let rows = app.buttons.matching(
                NSPredicate(format: "label CONTAINS 'Checking off' OR label CONTAINS 'depends on the view'"))
            try XCTSkipUnless(
                rows.firstMatch.waitForExistence(timeout: 20), "메모 DB 말고 체크할 칸이 있는 DB가 연결에 하나 더 있어야 한다")
            XCTAssertFalse(rows.allElementsBoundByIndex.contains { $0.label.hasPrefix("할 일 메모") }, "고른 DB는 다시 나오지 않는다")
            let row = rows.firstMatch
            let title = try XCTUnwrap(row.label.components(separatedBy: ", ").first)
            attachScreenshot("add database")
            row.tap()
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 5), .completed, "고르면 더할 수 있다")
            add.tap()
            XCTAssertTrue(wait(picker, "value ENDSWITH %@", " · \(title)", timeout: 20), "더한 DB의 뷰가 열린다")

            app.buttons["Settings"].firstMatch.tap()
            let remove = app.buttons["Remove “\(title)”"].firstMatch
            XCTAssertTrue(remove.waitForExistence(timeout: 10))
            attachScreenshot("settings databases")
            remove.tap()
            XCTAssertTrue(waitForDisappearance(remove, timeout: 5), "뺀 DB는 설정 목록에서 사라진다")
            app.buttons["Done"].firstMatch.tap()
            XCTAssertTrue(
                wait(picker, "value ENDSWITH %@", " · \(originalDatabase)", timeout: 10), "보던 DB를 빼면 남은 DB로 돌아온다")
        #else
            throw XCTSkip("Mac 사이드바의 DB 추가·빼기는 아직 UI 테스트가 없다")
        #endif
    }

    /// 줄을 끌어 순서를 바꾸면 다시 열어도 그대로이고, 섹션을 만들어 메모를 담고 섹션째 옮길 수 있다.
    /// 순서와 섹션은 기기에만 남는다.
    func testReorderAndSections() throws {
        #if os(iOS)
            relaunchWithoutLayouts()
            let stamp = Int(Date().timeIntervalSince1970)
            let first = "순서 가 \(stamp)"
            let second = "순서 나 \(stamp)"
            for title in [first, second] {
                press(composer)
                composer.typeText(title + "\n")
                XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 10))
                // Notion에 올라가 ID가 정해질 때까지 기다린다 (대기 중인 줄은 고칠 수 없다).
                XCTAssertTrue(wait(checkButton(title), "value != %@", "Waiting to sync", timeout: 20))
            }
            let a = app.staticTexts[first].firstMatch
            let b = app.staticTexts[second].firstMatch
            XCTAssertLessThan(b.frame.minY, a.frame.minY, "새 메모는 맨 위에 온다")

            // 먼저 적은 메모를 길게 눌러 맨 위로 끈다.
            drag(a, above: b)
            XCTAssertTrue(waitUntil(timeout: 5) { a.frame.minY < b.frame.minY }, "끌어 놓은 순서대로 보여야 한다")
            attachScreenshot("1 reordered")

            // 다시 열어도 (Notion에서 새로 받아도) 정한 순서가 남는다.
            app.terminate()
            app.launch()
            XCTAssertTrue(a.waitForExistence(timeout: 20))
            sleep(4)  // 새로 받은 목록으로 바뀔 시간
            XCTAssertLessThan(a.frame.minY, b.frame.minY, "정한 순서는 기기에 저장된다")

            // 섹션을 만들고 이름을 적는다. 빈 섹션에는 끌어다 놓으라는 안내가 보인다.
            let header = addSection("묶음 \(stamp)")
            let hint = app.staticTexts["Touch and hold a memo, then drag it here."].firstMatch
            XCTAssertTrue(hint.waitForExistence(timeout: 5))
            attachScreenshot("2 empty section")

            // 빈 섹션에 끌어 놓으면 섹션에 들어간다.
            drag(a, below: hint)
            XCTAssertTrue(waitUntil(timeout: 5) { a.frame.minY > header.frame.minY }, "섹션에 넣은 메모는 섹션 머리 아래에 온다")
            XCTAssertLessThan(b.frame.minY, header.frame.minY, "나머지는 섹션 밖에 남는다")
            XCTAssertTrue(waitForDisappearance(hint, timeout: 3), "메모가 들어가면 안내는 사라진다")

            // 다른 메모는 섹션 안 메모 아래에 놓는다.
            drag(b, below: a)
            XCTAssertTrue(waitUntil(timeout: 5) { b.frame.minY > a.frame.minY }, "섹션 안에서도 놓은 자리에 온다")
            attachScreenshot("3 section with memos")

            // 섹션 안 메모를 섹션 머리 위로 끌면 섹션 밖으로 나온다.
            drag(a, above: header)
            XCTAssertTrue(waitUntil(timeout: 5) { a.frame.minY < header.frame.minY }, "섹션 밖으로 끌어낼 수 있다")
            XCTAssertGreaterThan(b.frame.minY, header.frame.minY)

            // 섹션 머리를 끌면 섹션이 담긴 메모와 함께 옮겨 간다.
            let other = addSection("묶음 둘 \(stamp)")
            XCTAssertGreaterThan(other.frame.minY, b.frame.minY, "새 섹션은 맨 아래에 생긴다")
            drag(other, above: header)
            XCTAssertTrue(waitUntil(timeout: 5) { other.frame.minY < header.frame.minY }, "머리를 끌면 섹션 순서가 바뀐다")
            XCTAssertGreaterThan(b.frame.minY, header.frame.minY, "섹션에 담긴 메모는 섹션을 따라간다")
            attachScreenshot("4 two sections")

            // 섹션은 섹션 밖 메모 사이로 들어가지 않는다: 그런 자리에 놓으면 제자리로 돌아온다.
            drag(other, above: a)
            sleep(2)
            XCTAssertGreaterThan(other.frame.minY, a.frame.minY, "섹션은 섹션 밖 메모 아래에 남는다")
            XCTAssertLessThan(other.frame.minY, header.frame.minY)

            // 정리: 섹션을 지우면 메모는 섹션 밖으로 나온다. 그다음 메모를 지운다.
            removeTestSections()
            XCTAssertTrue(waitForDisappearance(header, timeout: 5))
            XCTAssertFalse(other.exists)
            XCTAssertTrue(a.exists && b.exists, "섹션을 지워도 메모는 남는다")
            for row in [a, b] {
                row.swipeLeft()
                let button = app.buttons["Delete"].firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 3))
                button.tap()
                XCTAssertTrue(waitForDisappearance(row, timeout: 5))
            }
            sleep(6)  // 실행 취소 구간(4초)이 지나 휴지통 요청이 나갈 때까지
        #else
            throw XCTSkip("Mac의 끌어 옮기기는 아직 UI 테스트가 없다")
        #endif
    }

    /// 문맥 메뉴의 "Move to Section". 문맥 메뉴가 열려 있는 동안 XCUITest가 앱이 쉬기를 60초씩 기다려 4분쯤 걸리므로
    /// `TEST_RUNNER_NT_SLOW_UI=1`일 때만 돌린다.
    func testMoveToSectionFromContextMenu() throws {
        #if os(iOS)
            try XCTSkipUnless(ProcessInfo.processInfo.environment["NT_SLOW_UI"] == "1", "느린 테스트: TEST_RUNNER_NT_SLOW_UI=1로 켠다")
            relaunchWithoutLayouts()
            let stamp = Int(Date().timeIntervalSince1970)
            let title = "순서 가 \(stamp)"
            press(composer)
            composer.typeText(title + "\n")
            let memo = app.staticTexts[title].firstMatch
            XCTAssertTrue(memo.waitForExistence(timeout: 10))
            XCTAssertTrue(wait(checkButton(title), "value != %@", "Waiting to sync", timeout: 20))

            let sectionTitle = "묶음 \(stamp)"
            let header = addSection(sectionTitle)

            memo.press(forDuration: 1.0)
            let moveMenu = app.buttons["Move to Section"].firstMatch
            XCTAssertTrue(moveMenu.waitForExistence(timeout: 5))
            moveMenu.tap()
            let target = app.buttons[sectionTitle].firstMatch
            XCTAssertTrue(target.waitForExistence(timeout: 5))
            target.tap()
            XCTAssertTrue(waitUntil(timeout: 5) { memo.frame.minY > header.frame.minY }, "메뉴로 고른 섹션에 들어간다")

            removeTestSections()
            XCTAssertTrue(waitForDisappearance(header, timeout: 5))
            memo.swipeLeft()
            let button = app.buttons["Delete"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.tap()
            XCTAssertTrue(waitForDisappearance(memo, timeout: 5))
            sleep(6)  // 실행 취소 구간(4초)이 지나 휴지통 요청이 나갈 때까지
        #else
            throw XCTSkip("iOS에서만 돌린다")
        #endif
    }

    // MARK: 도우미

    #if os(iOS)
        /// 줄을 길게 눌러 위쪽에 있는 다른 줄 바로 위에 놓는다.
        func drag(_ row: XCUIElement, above other: XCUIElement) { drag(row, onto: other, dy: -12) }

        /// 줄을 길게 눌러 아래쪽에 있는 다른 줄 바로 아래에 놓는다.
        func drag(_ row: XCUIElement, below other: XCUIElement) { drag(row, onto: other, dy: 12) }

        /// `row`와 `other`는 줄의 제목 글자다. 놓는 자리는 `other` 줄의 위쪽 절반(dy < 0)이나 아래쪽 절반(dy > 0).
        /// 누르는 시간이 길면 문맥 메뉴가 다 펼쳐져 끌기가 메뉴 고르기로 바뀌므로 줄이 들리자마자 움직인다.
        private func drag(_ row: XCUIElement, onto other: XCUIElement, dy: CGFloat) {
            let from = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = other.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: dy))
            from.press(forDuration: 0.6, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.8)
        }
    #endif

    /// 툴바의 정리 메뉴로 섹션을 만들고 이름을 적는다. 섹션 머리의 제목 글자를 돌려준다.
    @discardableResult
    func addSection(_ title: String) -> XCUIElement {
        app.buttons["Organize"].firstMatch.tap()
        app.buttons["New Section"].firstMatch.tap()
        let nameField = app.textFields["section-name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "새 섹션은 바로 이름을 적게 한다")
        nameField.typeText(title + "\n")
        let header = app.staticTexts[title].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), "적은 이름이 섹션 머리에 보인다")
        return header
    }

    /// 기기에만 있는 순서·섹션을 지우고 다시 연다. 실패한 실행이 남긴 섹션은 Notion 쪽을 정리해도 없어지지 않는다.
    func relaunchWithoutLayouts() {
        app.terminate()
        app.launchEnvironment["NT_DEV_RESET_LAYOUTS"] = "1"
        app.launch()
        // 이 뒤에 다시 열 때는 지우지 않는다 (저장된 순서가 남는지 본다).
        app.launchEnvironment["NT_DEV_RESET_LAYOUTS"] = nil
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
    }

    /// 테스트가 만든 섹션("묶음 …")을 섹션 머리의 ••• 메뉴로 지운다.
    func removeTestSections() {
        let options = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Section options, 묶음 "))
        for _ in 0..<10 {
            guard options.firstMatch.waitForExistence(timeout: 1) else { return }
            options.firstMatch.tap()
            let delete = app.buttons["Delete Section"].firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 3))
            delete.tap()
            sleep(1)
        }
    }

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }

    /// 시작할 목록 화면: 이 앱이 만든 메모 DB가 골라져 있는지 보고 시작 → 위젯 안내 → 목록.
    /// 메모 DB가 없으면 새로 만들지 않고 실패한다.
    func startWithStarterDatabase(screenshots: Bool = false) {
        let start = app.buttons["Start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 20), "연결되면 시작할 목록을 고르는 화면이 뜬다")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: start)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 20), .completed, "DB 목록을 받으면 시작할 수 있다")
        let starter = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "할 일 메모")).firstMatch
        XCTAssertTrue(starter.waitForExistence(timeout: 5))
        XCTAssertTrue(starter.isSelected, "이 앱이 만든 메모 DB가 미리 골라져 있어야 한다")
        if screenshots { attachScreenshot("3 source") }
        press(start)

        let writing = app.buttons["Start writing"].firstMatch
        XCTAssertTrue(writing.waitForExistence(timeout: 20))
        if screenshots { attachScreenshot("4 widgets") }
        press(writing)
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "온보딩을 마치면 목록이 열린다")
    }

    func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
