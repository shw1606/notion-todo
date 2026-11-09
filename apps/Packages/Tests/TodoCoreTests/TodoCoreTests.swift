import Foundation
import NotionKit
import Testing

@testable import TodoCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }

    static var probeSchema: DataSource { get throws { try load("data-source-probe") } }
    static var memoSchema: DataSource { get throws { try load("data-source-memo") } }
}

// 실제 Notion 응답(scripts/probe-views.mjs로 수집, 개인정보 제거)으로 뷰 해석 규칙을 검증한다.
@Suite struct ViewResolverTests {
    @Test func memoTodoViewUsesCheckboxAndHidesDone() throws {
        let view = ViewResolver.resolve(view: try Fixture.load("view-memo-todo"), schema: try Fixture.memoSchema)
        #expect(view.completion == .checkbox(propertyId: "%3BQFf"))
        #expect(view.showsDone == false)
        #expect(view.filtersByCompletion)
        #expect(view.summary.isGoodDefault)
        #expect(view.createRules == [.checkbox(propertyId: "%3BQFf", value: false)])
        #expect(view.datePropertyId == nil)
        #expect(view.titlePropertyId == "title")
        #expect(view.summary.completionTarget == .checkbox(propertyName: "완료"))
        let body = view.queryBody()
        #expect(body["filter"] == ["property": ";QFf", "checkbox": ["equals": false]])
        #expect(body["sorts"]?.arrayValue?.count == 1)
        #expect(body["page_size"] == 100)
    }

    @Test func memoDoneViewShowsDone() throws {
        let view = ViewResolver.resolve(view: try Fixture.load("view-memo-done"), schema: try Fixture.memoSchema)
        #expect(view.completion == .checkbox(propertyId: "%3BQFf"))
        #expect(view.showsDone)
        #expect(!view.summary.isGoodDefault)
        // "완료함" 뷰에서 추가하면 완료 상태로 만들어진다 (뷰 조건 만족).
        #expect(view.createProperties(title: "x", ownerUserId: nil)["%3BQFf"] == ["checkbox": true])
    }

    @Test func apiStatusViewUsesStatusGroups() throws {
        let view = ViewResolver.resolve(view: try Fixture.load("view-api-status"), schema: try Fixture.probeSchema)
        guard case .status(let prop, let done, let undo, let complete) = view.completion else {
            Issue.record("expected status, got \(view.completion)")
            return
        }
        #expect(prop == "BpXx")
        #expect(done == "088f62a2-eef8-4067-b05e-070657ab559d")  // Done (Complete 그룹)
        #expect(undo == "f051842f-2637-49c1-8b03-62865746e69b")  // Not started (To-do 그룹)
        #expect(complete == [done])
        #expect(view.showsDone == false)
        #expect(view.completionPatch(done: true) == ["BpXx": ["status": ["id": .string(done)]]])
        #expect(view.completionPatch(done: false) == ["BpXx": ["status": ["id": .string(undo)]]])
        #expect(view.summary.completionTarget == .status(propertyName: "상태", doneOptionName: "Done"))
    }

    @Test func uiQuickFilterMeIsMergedAndFilledOnCreate() throws {
        let view = ViewResolver.resolve(view: try Fixture.load("view-ui-me"), schema: try Fixture.probeSchema)
        #expect(view.filter == ["property": "iXlT", "people": ["contains": "me"]])
        #expect(view.createRules == [.peopleMe(propertyId: "iXlT")])
        let props = view.createProperties(title: "새 할 일", ownerUserId: "user-1")
        #expect(props["iXlT"] == ["people": [["id": "user-1"]]])
        #expect(props["title"] == ["title": [["text": ["content": "새 할 일"]]]])
        // 필터에 완료 조건이 없으면 DB에 하나뿐인 status를 쓴다.
        if case .status = view.completion {} else { Issue.record("expected status fallback") }
    }

    @Test func uiTodayFilterIsRelativeAndDateDependent() throws {
        let view = ViewResolver.resolve(view: try Fixture.load("view-ui-today"), schema: try Fixture.probeSchema)
        #expect(view.filter == ["property": "~:x|", "date": ["equals": "today"]])
        #expect(view.dependsOnDate)
        #expect(view.datePropertyId == "~%3Ax%7C")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = try Date("2026-11-09T15:30:00Z", strategy: .iso8601)  // 서울 11월 10일 00:30
        let props = view.createProperties(title: "x", ownerUserId: nil, now: now, calendar: calendar)
        #expect(props["~%3Ax%7C"] == ["date": ["start": "2026-11-10"]])
    }

    @Test func defaultViewWithoutFilterFallsBack() throws {
        let view = ViewResolver.resolve(view: try Fixture.load("view-ui-default"), schema: try Fixture.probeSchema)
        #expect(view.filter == nil)
        #expect(!view.filtersByCompletion)
        #expect(view.queryBody()["filter"] == nil)
        #expect(!view.dependsOnDate)
        #expect(view.datePropertyId == "~%3Ax%7C")  // 유일한 date 속성
        if case .status = view.completion {} else { Issue.record("expected status fallback") }
    }

    @Test func pagesBecomeItems() throws {
        let view = ViewResolver.resolve(view: try Fixture.load("view-ui-default"), schema: try Fixture.probeSchema)
        let pages: ListResponse<Page> = try Fixture.load("query-probe")
        let items = pages.results.map(view.item(from:))
        #expect(Set(items.map(\.title)) == ["A (나, 오늘)", "B (담당자 없음, 오늘)", "C (나, 내일)"])
        #expect(items.allSatisfy { !$0.isDone })
        #expect(items.first { $0.title.hasPrefix("C") }?.due == "2026-11-10")
    }

    @Test func memoPagesBecomeItems() throws {
        let view = ViewResolver.resolve(view: try Fixture.load("view-memo-todo"), schema: try Fixture.memoSchema)
        let pages: ListResponse<Page> = try Fixture.load("query-memo")
        #expect(Set(pages.results.map(view.item(from:)).map(\.title)) == ["치약 사기", "택배 반품 접수"])
    }

    @Test func mergeFlattensExistingAnd() {
        let view = NotionView(
            id: "v", name: "v", dataSourceId: "ds",
            filter: ["and": [["property": "a", "checkbox": ["equals": false]]]],
            quickFilters: ["b": ["select": ["equals": "X"]], "c": [:], "d": ["select": [:]]])
        #expect(
            ViewResolver.mergedFilter(view)
                == ["and": [["property": "a", "checkbox": ["equals": false]], ["select": ["equals": "X"], "property": "b"]]])
    }

    @Test func orBranchesAreNotRequired() {
        let filter: JSONValue = [
            "or": [["property": "a", "checkbox": ["equals": false]], ["property": "b", "checkbox": ["equals": false]]],
        ]
        #expect(ViewResolver.requiredConditions(filter).isEmpty)
    }

    @Test func ambiguousWithoutFilterIsReadOnly() {
        let schema = DataSource(
            id: "ds", title: [], properties: [
                "Name": PropertySchema(id: "title", name: "Name", type: "title"),
                "A": PropertySchema(id: "a", name: "A", type: "checkbox"),
                "B": PropertySchema(id: "b", name: "B", type: "checkbox"),
            ])
        let view = ViewResolver.resolve(view: NotionView(id: "v", name: "v", dataSourceId: "ds"), schema: schema)
        #expect(view.completion == .readOnly(.ambiguous))
        let picked = ViewResolver.resolve(
            view: NotionView(id: "v", name: "v", dataSourceId: "ds", filter: ["property": "b", "checkbox": ["equals": false]]),
            schema: schema)
        #expect(picked.completion == .checkbox(propertyId: "b"))
    }

    @Test func noCompletionPropertyIsReadOnly() {
        let schema = DataSource(
            id: "ds", title: [], properties: ["Name": PropertySchema(id: "title", name: "Name", type: "title")])
        let view = ViewResolver.resolve(view: NotionView(id: "v", name: "v", dataSourceId: "ds"), schema: schema)
        #expect(view.completion == .readOnly(.noCompletionProperty))
        #expect(view.completionTarget == nil)
    }

    @Test func databaseChoicesNeedSomethingToCheck() throws {
        let search = try Fixture.load("search-data-sources", as: ListResponse<DataSource>.self)
        let choices = search.results.compactMap(DatabaseChoice.init)
        #expect(choices.map(\.title) == ["할 일 메모", "probe-views 테스트"])
        #expect(choices.map(\.isStarter) == [true, false])
        #expect(choices[0].completionTarget == .checkbox(propertyName: "완료"))
        // 뷰 필터 없이 스키마만 보면 하나뿐인 status가 체크 대상이다.
        #expect(choices[1].completionTarget == .status(propertyName: "상태", doneOptionName: "Done"))

        var plain = try Fixture.memoSchema
        plain.properties = plain.properties.filter { $0.value.type != "checkbox" }
        #expect(DatabaseChoice(plain) == nil, "체크할 칸이 없는 DB는 후보가 아니다")
    }

    @Test func preferredDefaultSkipsDoneViews() throws {
        let done = ViewResolver.resolve(view: try Fixture.load("view-memo-done"), schema: try Fixture.memoSchema)
        let todo = ViewResolver.resolve(view: try Fixture.load("view-memo-todo"), schema: try Fixture.memoSchema)
        // API 목록 순서대로 "완료함"이 먼저 와도 "할 일"을 고른다.
        #expect([done.summary, todo.summary].preferredDefault?.id == todo.id)
    }

    @Test func viewsGroupByDatabaseInOrder() throws {
        let todo = ViewResolver.resolve(view: try Fixture.load("view-memo-todo"), schema: try Fixture.memoSchema).summary
        var done = ViewResolver.resolve(view: try Fixture.load("view-memo-done"), schema: try Fixture.memoSchema).summary
        done.dataSourceId = NotionID.compact(done.dataSourceId)  // 대시가 없어도 같은 DB
        var other = todo
        other.id = "v-other"
        other.dataSourceId = "other-ds"  // 이름이 같아도 다른 DB는 따로 묶는다
        let groups = [todo, other, done].byDatabase
        #expect(groups.map(\.id) == [todo.dataSourceId, "other-ds"])
        #expect(groups.map(\.title) == ["할 일 메모", "할 일 메모"])
        #expect(groups[0].views.map(\.id) == [todo.id, done.id])
    }
}

@Suite struct AuthTests {
    @Test func pkceMatchesRFC7636() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let pkce = PKCE(verifier: "v", nonce: "n")
        #expect(pkce.state == "n.\(PKCE.challenge(for: "v"))")
    }

    @Test func authorizeURL() throws {
        let config = OAuthConfig(clientId: "cid", authBaseURL: URL(string: "https://auth.example.com")!)
        let url = config.authorizeURL(pkce: PKCE(verifier: "v", nonce: "n"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "redirect_uri" }?.value == "https://auth.example.com/callback")
        #expect(items.first { $0.name == "owner" }?.value == "user")
        // 함수의 /callback이 결과를 앱 스킴으로 넘긴다 (Info.plist의 CFBundleURLSchemes와 같아야 한다).
        #expect(OAuthConfig.callbackScheme == "notiontodo")
    }

    @Test func refreshUsesTokenAlreadyRotatedByOtherProcess() async throws {
        let store = InMemoryCredentialStore(Credentials(kind: .oauth, accessToken: "new", refreshToken: "r2"))
        let session = AuthSession(store: store, config: nil)
        #expect(try await session.refreshAfterUnauthorized(failedToken: "old") == "new")
    }

    @Test func internalTokenCannotRefresh() async throws {
        let store = InMemoryCredentialStore(Credentials(kind: .internalToken, accessToken: "t"))
        let session = AuthSession(store: store, config: nil)
        #expect(try await session.refreshAfterUnauthorized(failedToken: "t") == nil)
    }

    @Test func configurationIgnoresUnsubstitutedValues() {
        let config = AppConfiguration.fromBundle(Bundle(for: BundleToken.self))
        #expect(config.oauth == nil)
    }
}

final class BundleToken {}
