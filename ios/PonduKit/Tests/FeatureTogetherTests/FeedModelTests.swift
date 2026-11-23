import XCTest
import PonduCore
@testable import FeatureTogether

@MainActor
final class FeedModelTests: XCTestCase {
    private func ids(_ model: FeedModel) -> [UUID] { model.items.map(\.id) }

    // MARK: 피드 넘김과 중복 제거

    func testFirstPageUsesNilCursorAndLimit20() async {
        let backend = FakeBackend()
        let a = UUID(), b = UUID()
        backend.on("get_feed") { _ in Fixtures.page([Fixtures.card(id: a), Fixtures.card(id: b)], next: "c1") }
        backend.on("list_my_crews") { _ in Fixtures.json([]) }
        let model = FeedModel(backend: backend)

        await model.reload()

        XCTAssertEqual(ids(model), [a, b])
        XCTAssertEqual(model.phase, .ready)
        let feed = backend.calls(named: "get_feed")
        XCTAssertEqual(feed.count, 1)
        XCTAssertEqual(feed[0].params["p_cursor"], .null)
        XCTAssertEqual(feed[0].params["p_limit"], .number(20))
        XCTAssertEqual(feed[0].params["p_group_id"], .null)
    }

    func testLoadMoreSendsCursorAppendsAndDropsDuplicates() async {
        let backend = FakeBackend()
        let a = UUID(), b = UUID(), c = UUID()
        backend.on("list_my_crews") { _ in Fixtures.json([]) }
        backend.on("get_feed") { params in
            if params["p_cursor"] == .null {
                return Fixtures.page([Fixtures.card(id: a), Fixtures.card(id: b)], next: "c1")
            }
            // 둘째 쪽에 b가 다시 들어오고, 같은 쪽 안에서도 c가 두 번 온다.
            return Fixtures.page([Fixtures.card(id: b), Fixtures.card(id: c), Fixtures.card(id: c)], next: nil)
        }
        let model = FeedModel(backend: backend)
        await model.reload()

        await model.loadMore()

        XCTAssertEqual(ids(model), [a, b, c])
        XCTAssertEqual(backend.calls(named: "get_feed")[1].params["p_cursor"], .string("c1"))
        XCTAssertFalse(model.hasMore)

        await model.loadMore()   // 더 없으면 요청하지 않는다
        XCTAssertEqual(backend.calls(named: "get_feed").count, 2)
    }

    func testCrewScopePassesGroupID() async {
        let backend = FakeBackend()
        let crewID = UUID()
        backend.on("list_my_crews") { _ in Fixtures.json([]) }
        backend.on("get_feed") { _ in Fixtures.page([], next: nil) }
        let model = FeedModel(backend: backend)

        await model.setScope(.crew(crewID))

        XCTAssertEqual(backend.calls(named: "get_feed").last?.params["p_group_id"], .string(crewID.uuidString.lowercased()))
    }

    // MARK: 반응

    func testReactionShowsImmediatelyThenKeepsOnSuccess() async throws {
        let backend = FakeBackend()
        let a = UUID()
        backend.on("list_my_crews") { _ in Fixtures.json([]) }
        backend.on("get_feed") { _ in Fixtures.page([Fixtures.card(id: a, reactionCount: 2)], next: nil) }
        backend.on("set_reaction") { _ in
            try await Task.sleep(for: .milliseconds(150))
            return Data("null".utf8)
        }
        let model = FeedModel(backend: backend)
        await model.reload()

        let task = Task { await model.toggleReaction(on: a) }
        try await Task.sleep(for: .milliseconds(40))
        // 서버 응답 전인데 이미 반영돼 있어야 한다.
        XCTAssertEqual(model.items[0].myReaction, FeedModel.reactionKind)
        XCTAssertEqual(model.items[0].reactionCount, 3)
        await task.value
        XCTAssertEqual(model.items[0].myReaction, FeedModel.reactionKind)
        XCTAssertEqual(model.items[0].reactionCount, 3)
        XCTAssertNil(model.toast)
    }

    func testReactionRevertsAndAlertsOnFailure() async {
        let backend = FakeBackend()
        let a = UUID()
        backend.on("list_my_crews") { _ in Fixtures.json([]) }
        backend.on("get_feed") { _ in Fixtures.page([Fixtures.card(id: a, reactionCount: 2)], next: nil) }
        backend.on("set_reaction") { _ in throw BackendError(code: "network") }
        let model = FeedModel(backend: backend)
        await model.reload()

        await model.toggleReaction(on: a)

        XCTAssertNil(model.items[0].myReaction)
        XCTAssertEqual(model.items[0].reactionCount, 2)
        XCTAssertNotNil(model.toast)
    }

    func testTappingMyReactionCancelsWithNullKind() async {
        let backend = FakeBackend()
        let a = UUID()
        backend.on("list_my_crews") { _ in Fixtures.json([]) }
        backend.on("get_feed") { _ in Fixtures.page([Fixtures.card(id: a, myReaction: "cheer", reactionCount: 1)], next: nil) }
        backend.on("set_reaction") { _ in Data("null".utf8) }
        let model = FeedModel(backend: backend)
        await model.reload()

        await model.toggleReaction(on: a)

        XCTAssertNil(model.items[0].myReaction)
        XCTAssertEqual(model.items[0].reactionCount, 0)
        XCTAssertEqual(backend.calls(named: "set_reaction").last?.params["p_kind"], .null)
    }

    // MARK: 신고 후 숨김

    func testReportHidesImmediatelyAndStaysHiddenAfterReload() async throws {
        let backend = FakeBackend()
        let a = UUID(), b = UUID()
        backend.on("list_my_crews") { _ in Fixtures.json([]) }
        backend.on("get_feed") { _ in Fixtures.page([Fixtures.card(id: a), Fixtures.card(id: b)], next: nil) }
        backend.on("report_session") { _ in
            try await Task.sleep(for: .milliseconds(150))
            return Data("null".utf8)
        }
        let model = FeedModel(backend: backend)
        await model.reload()

        let task = Task { await model.report(sessionID: a, reason: "스팸") }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(ids(model), [b])          // 응답 전에 이미 숨김
        await task.value
        XCTAssertEqual(backend.calls(named: "report_session").last?.params["p_reason"], .string("스팸"))

        await model.reload()                     // 서버가 늦게 반영해도 다시 나타나지 않는다
        XCTAssertEqual(ids(model), [b])
    }

    func testReportFailureBringsCardBack() async {
        let backend = FakeBackend()
        let a = UUID(), b = UUID()
        backend.on("list_my_crews") { _ in Fixtures.json([]) }
        backend.on("get_feed") { _ in Fixtures.page([Fixtures.card(id: a), Fixtures.card(id: b)], next: nil) }
        backend.on("report_session") { _ in throw BackendError(code: "timeout") }
        let model = FeedModel(backend: backend)
        await model.reload()

        await model.report(sessionID: a, reason: "기타")

        XCTAssertEqual(ids(model), [a, b])
        XCTAssertNotNil(model.toast)
    }

    func testBlockRemovesAllCardsOfAuthor() async {
        let backend = FakeBackend()
        let bad = UUID()
        let keep = UUID()
        backend.on("list_my_crews") { _ in Fixtures.json([]) }
        backend.on("get_feed") { _ in
            Fixtures.page([Fixtures.card(authorID: bad), Fixtures.card(authorID: keep), Fixtures.card(authorID: bad)], next: nil)
        }
        backend.on("block_user") { _ in Data("null".utf8) }
        let model = FeedModel(backend: backend)
        await model.reload()
        let author = model.items[0].card.author

        await model.block(author: author)

        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items[0].card.author.id, keep)
    }

    // MARK: 같이 하기

    func testJoinRequestCarriesSessionIDAndPartnerName() async {
        let backend = FakeBackend()
        let a = UUID()
        backend.on("list_my_crews") { _ in Fixtures.json([]) }
        backend.on("get_feed") { _ in Fixtures.page([Fixtures.card(id: a, authorName: "가온")], next: nil) }
        let model = FeedModel(backend: backend)
        await model.reload()
        var received: StartSessionRequest?
        model.onJoin = { received = $0 }

        model.join(model.items[0].card)

        XCTAssertEqual(received?.joinedSessionID, a)
        XCTAssertEqual(received?.joinedWithName, "가온")
        XCTAssertEqual(received?.category, model.items[0].card.primaryCategory)
    }

    func testJoinOnlyOffersActiveSessionsOfOthers() async {
        let backend = FakeBackend()
        backend.on("list_my_crews") { _ in Fixtures.json([]) }
        backend.on("get_feed") { _ in
            Fixtures.page([Fixtures.card(status: "live"), Fixtures.card(status: "ended"),
                           Fixtures.card(authorID: backend.currentUserID!, status: "live")], next: nil)
        }
        let model = FeedModel(backend: backend)
        await model.reload()

        XCTAssertEqual(model.items.map { model.canJoin($0) }, [true, false, false])
    }

    // MARK: 크루 이름과 제목 대신 쓰는 분야 이름

    func testCardKeepsGroupNameAndFallsBackToCategoryTitle() async {
        let backend = FakeBackend()
        backend.on("list_my_crews") { _ in Fixtures.json([]) }
        backend.on("get_feed") { _ in
            Fixtures.page([Fixtures.card(shareTitle: nil, groupName: "스터디"), Fixtures.card()], next: nil)
        }
        let model = FeedModel(backend: backend)
        await model.reload()

        XCTAssertEqual(model.items[0].card.groupName, "스터디")
        XCTAssertEqual(model.items[0].card.displayTitle, "공부")     // share_title이 null이면 분야 이름
        XCTAssertNil(model.items[1].card.groupName)
        XCTAssertEqual(model.items[1].card.displayTitle, "DB 과제")
    }

    // MARK: 문구

    func testMethodLabelsNeverSayCertification() {
        let all = TogetherText.methodLabels(captureMode: .inAppPhoto, endCorrected: true, offlineStarted: true)
        XCTAssertEqual(all, ["앱 촬영 첨부", "나중에 정정함", "오프라인 시작"])
        XCTAssertEqual(TogetherText.methodLabels(captureMode: .noPhoto, endCorrected: false, offlineStarted: false), ["사진 없는 기록"])
        XCTAssertFalse((all + [TogetherText.minutesText(seconds: 2220, isLive: true)]).joined().contains("인증"))
    }
}
