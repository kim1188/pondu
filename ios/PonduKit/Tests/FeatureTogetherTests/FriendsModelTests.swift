import XCTest
import PonduCore
@testable import FeatureTogether

@MainActor
final class FriendsModelTests: XCTestCase {
    private func searchBackend() -> FakeBackend {
        let backend = FakeBackend()
        backend.on("search_profiles") { params in
            guard case .string(let q)? = params["p_query"] else { return Fixtures.json([]) }
            return Fixtures.json([Fixtures.profile(name: q, handle: q)])
        }
        return backend
    }

    // MARK: 검색 지연

    func testSearchWaitsUntilTypingPausesAndSendsOnlyLastQuery() async throws {
        let backend = searchBackend()
        let model = FriendsModel(backend: backend, debounce: .milliseconds(100))

        model.queryChanged("g")
        try await Task.sleep(for: .milliseconds(30))
        model.queryChanged("ga")
        try await Task.sleep(for: .milliseconds(30))
        model.queryChanged("gao")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(backend.calls(named: "search_profiles").count, 0)   // 아직 멈추지 않았다

        try await Task.sleep(for: .milliseconds(250))
        let calls = backend.calls(named: "search_profiles")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].params["p_query"], .string("gao"))
        XCTAssertEqual(model.results.first?.handle, "gao")
        XCTAssertEqual(model.searchPhase, .done)
    }

    func testStaleSlowResponseDoesNotOverwriteNewerResults() async throws {
        let backend = FakeBackend()
        backend.on("search_profiles") { params in
            guard case .string(let q)? = params["p_query"] else { return Fixtures.json([]) }
            if q == "old" { try await Task.sleep(for: .milliseconds(300)) }
            return Fixtures.json([Fixtures.profile(name: q, handle: q)])
        }
        let model = FriendsModel(backend: backend, debounce: .milliseconds(10))

        model.queryChanged("old")
        try await Task.sleep(for: .milliseconds(60))     // old 요청이 나간 뒤
        model.queryChanged("new")
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(model.results.map(\.handle), ["new"])
    }

    func testClearingQueryCancelsPendingSearch() async throws {
        let backend = searchBackend()
        let model = FriendsModel(backend: backend, debounce: .milliseconds(80))

        model.queryChanged("ga")
        model.queryChanged("")
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(backend.calls(named: "search_profiles").count, 0)
        XCTAssertEqual(model.searchPhase, .idle)
        XCTAssertTrue(model.results.isEmpty)
    }

    // MARK: 요청·수락·삭제

    private func listBackend(friends: [[String: Any]] = [], incoming: [[String: Any]] = []) -> FakeBackend {
        let backend = FakeBackend()
        backend.on("list_friends") { _ in Fixtures.json(friends) }
        backend.on("list_friend_requests") { _ in Fixtures.json(["incoming": incoming, "outgoing": []]) }
        return backend
    }

    func testAcceptMovesRequestToFriendsImmediatelyAndRevertsOnFailure() async {
        let requester = UUID()
        let backend = listBackend(incoming: [Fixtures.profile(id: requester, name: "나래", handle: "narae")])
        backend.on("respond_friend_request") { _ in throw BackendError(code: "request_not_found") }
        let model = FriendsModel(backend: backend)
        await model.load()
        XCTAssertEqual(model.incoming.count, 1)

        await model.respond(to: model.incoming[0], accept: true)

        XCTAssertEqual(model.incoming.count, 1)      // 실패해서 되돌림
        XCTAssertTrue(model.friends.isEmpty)
        XCTAssertNotNil(model.toast)
    }

    func testAcceptSuccessAddsFriend() async {
        let backend = listBackend(incoming: [Fixtures.profile(name: "나래", handle: "narae")])
        backend.on("respond_friend_request") { _ in Data("null".utf8) }
        let model = FriendsModel(backend: backend)
        await model.load()

        await model.respond(to: model.incoming[0], accept: true)

        XCTAssertTrue(model.incoming.isEmpty)
        XCTAssertEqual(model.friends.map(\.handle), ["narae"])
        XCTAssertEqual(backend.calls(named: "respond_friend_request").last?.params["p_accept"], .bool(true))
    }

    func testSendRequestMarksRequestedAndRevertsOnFailure() async throws {
        let backend = listBackend()
        backend.on("search_profiles") { _ in Fixtures.json([Fixtures.profile(name: "다온", handle: "daon")]) }
        backend.on("send_friend_request") { _ in throw BackendError(code: "blocked") }
        let model = FriendsModel(backend: backend, debounce: .milliseconds(10))
        await model.load()
        model.queryChanged("daon")
        try await Task.sleep(for: .milliseconds(150))
        let user = try XCTUnwrap(model.results.first)

        await model.sendRequest(to: user)

        XCTAssertEqual(model.relation(to: user.id), .none)
        XCTAssertNotNil(model.toast)
    }

    func testLoadFetchesBothListsAndReportsEmptyState() async {
        let backend = listBackend()
        let model = FriendsModel(backend: backend)

        await model.load()

        XCTAssertTrue(model.hasNoRelations)
        XCTAssertEqual(backend.calls(named: "list_friends").count, 1)
        XCTAssertEqual(backend.calls(named: "list_friend_requests").count, 1)
    }
}
