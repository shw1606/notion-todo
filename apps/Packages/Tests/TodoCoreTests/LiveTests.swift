import Foundation
import NotionKit
import Testing

@testable import TodoCore

/// 실제 Notion에 붙는 테스트. `NT_LIVE_TOKEN`(테스트용 OAuth/internal 토큰)이 있을 때만 돈다.
///
///     NT_LIVE_TOKEN=$(node -p 'require("../../.probe/oauth-token.json").access_token') swift test --filter Live
///
/// 연결에 공유된 DB의 뷰마다 조회하고, 체크 가능한 뷰에서는 첫 항목을 체크했다가 되돌린다.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NT_LIVE_TOKEN"] != nil))
struct LiveTests {
    let repository: TodoRepository

    init() {
        let token = ProcessInfo.processInfo.environment["NT_LIVE_TOKEN"] ?? ""
        let auth = AuthSession(store: InMemoryCredentialStore(Credentials(kind: .oauth, accessToken: token)), config: nil)
        let store = SharedStore(root: FileManager.default.temporaryDirectory.appending(path: "nt-live-\(UUID().uuidString)"))
        repository = TodoRepository(client: NotionClient(tokens: auth), store: store, auth: auth)
    }

    /// 온보딩의 "토큰 붙여 넣기" 경로: users/me로 확인하고 저장소에 넣는다.
    @Test func tokenSignInReadsWorkspace() async throws {
        let token = ProcessInfo.processInfo.environment["NT_LIVE_TOKEN"] ?? ""
        let store = InMemoryCredentialStore(nil)
        let credentials = try await AuthSession(store: store, config: nil).signIn(internalToken: token)
        #expect(credentials.kind == .internalToken)
        #expect(credentials.workspaceName != nil)
        #expect(store.load() == credentials)
    }

    @Test func everyViewQueriesAndTogglesRoundTrip() async throws {
        await repository.saveDatabaseIds(try await repository.databaseChoices().map(\.id))
        let catalog = try await repository.catalog(refresh: true)
        #expect(!catalog.isEmpty)
        for summary in catalog {
            let snapshot = try await repository.fetchItems(summary.id)
            print("[live] \(summary.databaseTitle) / \(summary.name): \(snapshot.items.map(\.title)) writable=\(summary.isWritable) showsDone=\(summary.showsDone)")
            guard summary.isWritable, let first = snapshot.items.first else { continue }
            try await repository.setDone(viewId: summary.id, itemId: first.id, done: !first.isDone)
            #expect(await repository.pendingCount == 0)
            let after = try await repository.fetchItems(summary.id)
            let resolved = try await repository.resolvedView(summary.id)
            if resolved.filtersByCompletion, !summary.showsDone, !first.isDone {
                #expect(!after.items.contains { $0.id == first.id }, "체크한 항목은 미완료 뷰에서 빠져야 한다")
            }
            try await repository.setDone(viewId: summary.id, itemId: first.id, done: first.isDone)
            #expect(await repository.pendingCount == 0)
        }
        let preferred = try #require(catalog.preferredDefault)
        print("[live] preferred default: \(preferred.databaseTitle) / \(preferred.name)")
        #expect(preferred.isGoodDefault)
    }
}
