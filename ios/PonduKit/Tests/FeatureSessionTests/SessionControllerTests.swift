import XCTest
import PonduCore
@testable import FeatureSession

/// 사진 줄이기를 대신하는 가짜: 폴더에 빈 파일 두 개를 쓴다.
struct FakePhotoProcessor: PhotoProcessing {
    var fail = false
    func process(imageData: Data, into directory: URL) async throws -> ProcessedPhoto {
        if fail { throw PhotoError.decode }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let full = directory.appendingPathComponent("full.heic")
        let thumb = directory.appendingPathComponent("thumb.heic")
        try Data([1, 2, 3]).write(to: full)
        try Data([1]).write(to: thumb)
        return ProcessedPhoto(fullURL: full, thumbURL: thumb, fullBytes: 3, thumbBytes: 1)
    }
}

final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    var uptime: TimeInterval = 1_000
}

@MainActor
final class SessionControllerTests: XCTestCase {
    var backend: StubBackend!
    var store: InMemoryPendingStore!
    var clock: TestClock!
    var photosDir: URL!

    override func setUp() async throws {
        backend = StubBackend()
        store = InMemoryPendingStore()
        clock = TestClock()
        photosDir = FileManager.default.temporaryDirectory.appendingPathComponent("pondu-test-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: photosDir)
    }

    private func makeController(processor: PhotoProcessing = FakePhotoProcessor()) -> SessionController {
        let c = clock!
        return SessionController(backend: backend, store: store, photoProcessor: processor, photosDirectory: photosDir,
                                 now: { c.date }, uptime: { c.uptime }, sleeper: { _ in await Task.yield() })
    }

    private func startRequest(category: ActivityCategory? = nil) -> StartSessionRequest {
        StartSessionRequest(category: category, threadID: nil, todoID: nil, planBlockID: nil, title: "개인 제목", joinedSessionID: nil, joinedWithName: nil)
    }

    /// 분야를 직접 지정해 시작 화면을 열고 시작을 누른다.
    private func startStudy(_ c: SessionController, photo: Bool = false) async {
        backend.on("list_threads", .json([Any]()))
        c.presentStart(startRequest())
        c.draft?.category = "study"
        if photo {
            c.capturePhoto(Data([0xFF]))
            await c.draft?.photoTask?.value
        }
        c.commitStart()
    }

    // MARK: 상태 전이에 따른 화면 상태

    func testStartShowsLiveImmediatelyBeforeServerResponds() async {
        let c = makeController()
        backend.on("start_session", .json(Fixture.session(duration: 0)))
        await startStudy(c)
        // 서버 응답 전에도 이미 진행 중 화면이다.
        XCTAssertNotNil(c.live)
        XCTAssertEqual(c.live?.phase, .live)
        XCTAssertEqual(c.route, .none)
        await c.waitUntilIdle()
        XCTAssertEqual(c.live?.serverID, UUID(uuidString: Fixture.sessionID))
        XCTAssertNotNil(c.liveSession)
    }

    func testStartSendsClientIDAndNoOfflineTimeOnline() async {
        let c = makeController()
        backend.on("start_session", .json(Fixture.session()))
        await startStudy(c)
        await c.waitUntilIdle()
        let p = backend.lastParams("start_session")!
        guard case .string(let cid)? = p["p_client_id"] else { return XCTFail("client id") }
        XCTAssertEqual(cid, cid.lowercased())
        XCTAssertEqual(p["p_primary_category"], .string("study"))
        XCTAssertEqual(p["p_capture_mode"], .string("no_photo"))
        XCTAssertEqual(p["p_visibility"], .string("private"))
        XCTAssertEqual(p["p_offline_started_at"], .null)
        // 개인 제목은 서버로 가지 않는다.
        XCTAssertEqual(p["p_share_title"], .null)
    }

    func testPauseAndResumeUpdateScreenAtOnce() async {
        let c = makeController()
        backend.on("start_session", .json(Fixture.session()))
        await startStudy(c)
        await c.waitUntilIdle()

        backend.on("pause_session", .json(Fixture.session(status: "paused", pausedAt: "2026-11-22T01:10:00Z", duration: 600)))
        c.togglePause()
        XCTAssertEqual(c.live?.phase, .paused)            // 서버 응답 전에 이미 바뀜
        await c.waitUntilIdle()
        XCTAssertEqual(c.live?.phase, .paused)
        XCTAssertEqual(c.live?.clock.running, false)

        backend.on("resume_session", .json(Fixture.session(status: "live", pausedSeconds: 60, duration: 600)))
        c.togglePause()
        XCTAssertEqual(c.live?.phase, .live)
        await c.waitUntilIdle()
        XCTAssertEqual(c.live?.clock.running, true)
    }

    func testEndClearsLiveAndStoresOutcome() async {
        let c = makeController()
        backend.on("start_session", .json(Fixture.session()))
        await startStudy(c)
        await c.waitUntilIdle()

        backend.on("end_session", .json(Fixture.session(status: "ended", duration: 1800, outcome: "more")))
        c.presentEnd()
        XCTAssertEqual(c.route, .end)
        c.endDraft.choice = .more
        c.endDraft.note = " 원인은 찾았고 수정이 남음 "
        c.commitEnd()
        XCTAssertNil(c.live)                               // 누르는 즉시 막대가 내려간다
        await c.waitUntilIdle()
        let p = backend.lastParams("end_session")!
        XCTAssertEqual(p["p_outcome"], .string("more"))
        XCTAssertEqual(p["p_progress_note"], .string("원인은 찾았고 수정이 남음"))
        XCTAssertNil(c.liveSession)
        XCTAssertNotNil(c.lastEndedSession)
    }

    func testEndWithoutNoteSendsNull() async {
        let c = makeController()
        backend.on("start_session", .json(Fixture.session()))
        await startStudy(c)
        await c.waitUntilIdle()
        backend.on("end_session", .json(Fixture.session(status: "ended", outcome: "done")))
        c.presentEnd(); c.endDraft.choice = .done; c.commitEnd()
        await c.waitUntilIdle()
        XCTAssertEqual(backend.lastParams("end_session")?["p_progress_note"], .null)
    }

    func testEndRequiresAChoice() async {
        let c = makeController()
        backend.on("start_session", .json(Fixture.session()))
        await startStudy(c)
        await c.waitUntilIdle()
        c.presentEnd()
        c.commitEnd()
        XCTAssertNotNil(c.live)
        XCTAssertEqual(backend.count("end_session"), 0)
    }

    // MARK: 실패 시 되돌리기

    func testPauseFailureRevertsAndAlerts() async {
        let c = makeController()
        backend.on("start_session", .json(Fixture.session()))
        await startStudy(c)
        await c.waitUntilIdle()
        let before = c.live

        backend.on("pause_session", .error(BackendError(code: "session_not_active")))
        c.togglePause()
        XCTAssertEqual(c.live?.phase, .paused)
        await c.waitUntilIdle()
        XCTAssertEqual(c.live, before)
        XCTAssertNotNil(c.alert)
    }

    func testEndFailureRestoresLiveSession() async {
        let c = makeController()
        backend.on("start_session", .json(Fixture.session()))
        await startStudy(c)
        await c.waitUntilIdle()
        let before = c.live

        backend.on("end_session", .error(BackendError(code: "timeout")))
        c.presentEnd(); c.endDraft.choice = .done; c.commitEnd()
        XCTAssertNil(c.live)
        await c.waitUntilIdle()
        XCTAssertEqual(c.live, before)
        XCTAssertNotNil(c.alert)
        XCTAssertNil(c.lastEndedSession)
    }

    func testStartRejectedRevertsAndAlerts() async {
        let c = makeController()
        backend.on("start_session", .error(BackendError(code: "visibility_not_available")))
        await startStudy(c)
        XCTAssertNotNil(c.live)
        await c.waitUntilIdle()
        XCTAssertNil(c.live)
        XCTAssertNotNil(c.alert)
        XCTAssertTrue(store.load().starts.isEmpty)   // 서버가 거절한 건 대기열에 두지 않는다
    }

    func testAlreadyActiveAdoptsExistingSession() async {
        let c = makeController()
        backend.on("start_session", .error(BackendError(code: "session_already_active")))
        backend.on("get_my_live_session", .json(Fixture.session(id: "bbbbbbbb-0000-0000-0000-000000000002", duration: 300)))
        await startStudy(c)
        await c.waitUntilIdle()
        XCTAssertEqual(c.live?.serverID, UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000002"))
    }

    // MARK: 오프라인 대기열

    func testOfflineStartIsQueuedThenSentWithOfflineStartedAt() async {
        let c = makeController()
        backend.on("start_session", .error(BackendError(code: "network")))
        backend.on("start_session", .json(Fixture.session(duration: 5, offlineStartedAt: "2026-11-22T00:59:55Z")))
        let tapped = clock.date
        await startStudy(c)
        await c.waitUntilIdle()   // 두 번째 시도(재시도)까지 끝난다

        XCTAssertEqual(backend.count("start_session"), 2)
        let first = backend.calls.first { $0.name == "start_session" }!.params
        let second = backend.lastParams("start_session")!
        XCTAssertEqual(first["p_client_id"], second["p_client_id"])       // 같은 키로 재시도
        XCTAssertEqual(first["p_offline_started_at"], .null)
        XCTAssertEqual(second["p_offline_started_at"], .string(ISODate.string(tapped)))
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertEqual(c.live?.isOfflineStart, true)
        XCTAssertNotNil(c.live?.serverID)
    }

    func testOfflineStartStaysQueuedWhileOffline() async {
        let c = makeController()
        backend.on("start_session", .error(BackendError(code: "network")))
        await startStudy(c)
        // 첫 시도 실패 직후 대기열에 들어가고 화면은 진행 중으로 남는다.
        await c.waitForStart()
        XCTAssertEqual(store.load().starts.count, 1)
        XCTAssertEqual(c.live?.isOfflineStart, true)
        XCTAssertNil(c.live?.serverID)
        await c.cancelFlush()
    }

    func testExpiredOfflineStartIsDropped() async {
        let c = makeController()
        backend.on("start_session", .error(BackendError(code: "network")))
        await startStudy(c)
        await c.waitForStart()
        await c.cancelFlush()
        XCTAssertEqual(store.load().starts.count, 1)

        clock.date = clock.date.addingTimeInterval(13 * 3600)
        backend.on("start_session", .json(Fixture.session()))
        c.retryPending()
        await c.waitUntilIdle()
        XCTAssertEqual(backend.count("start_session"), 1)   // 12시간이 지난 건 보내지 않는다
        XCTAssertNil(c.live)
        XCTAssertTrue(store.load().starts.isEmpty)
        XCTAssertNotNil(c.alert)
    }

    func testQueueSurvivesRelaunch() async {
        let first = makeController()
        backend.on("start_session", .error(BackendError(code: "network")))
        await startStudy(first)
        await first.waitForStart()
        await first.cancelFlush()

        clock.date = clock.date.addingTimeInterval(30)
        clock.uptime += 30
        let second = makeController()                        // 앱을 다시 켠 것과 같다
        XCTAssertNotNil(second.live)
        XCTAssertEqual(second.live?.isOfflineStart, true)
        XCTAssertEqual(second.live?.clock.elapsed(at: clock.uptime) ?? 0, 30, accuracy: 0.5)
    }

    func testPauseWhileStartNeverReachedServerRevertsWithMessage() async {
        let c = makeController()
        backend.on("start_session", .error(BackendError(code: "network")))
        await startStudy(c)
        await c.waitForStart()
        await c.cancelFlush()
        c.togglePause()
        await c.waitUntilIdle()
        XCTAssertEqual(c.live?.phase, .live)
        XCTAssertNotNil(c.alert)
        XCTAssertEqual(backend.count("pause_session"), 0)
    }

    // MARK: 사진

    func testPhotoStartDoesNotWaitForUploadAndUsesLowercasePaths() async {
        let c = makeController()
        backend.on("start_session", .json(Fixture.session(captureMode: "in_app_photo")))
        backend.on("attach_session_photo", .json(Fixture.session(captureMode: "in_app_photo")))
        await startStudy(c, photo: true)
        XCTAssertEqual(backend.lastParams("start_session"), nil)   // 아직 전송 전이어도 화면은 이미 진행 중
        XCTAssertNotNil(c.live)
        await c.waitUntilIdle()
        XCTAssertEqual(backend.lastParams("start_session")?["p_capture_mode"], .string("in_app_photo"))
        let paths = backend.uploads.map(\.path).sorted()
        XCTAssertEqual(paths, [
            "\(Fixture.userID)/\(Fixture.sessionID)/full.heic",
            "\(Fixture.userID)/\(Fixture.sessionID)/thumb.heic",
        ])
        XCTAssertEqual(backend.count("attach_session_photo"), 1)
        XCTAssertTrue(store.load().photos.isEmpty)
    }

    func testPhotoProcessingFailureFallsBackToNoPhoto() async {
        let c = makeController(processor: FakePhotoProcessor(fail: true))
        backend.on("start_session", .json(Fixture.session()))
        await startStudy(c, photo: true)
        await c.waitUntilIdle()
        XCTAssertEqual(backend.lastParams("start_session")?["p_capture_mode"], .string("no_photo"))
        XCTAssertTrue(backend.uploads.isEmpty)
    }

    func testPhotoUploadFailureKeepsItQueued() async {
        let c = makeController()
        backend.uploadError = BackendError(code: "network")
        backend.on("start_session", .json(Fixture.session(captureMode: "in_app_photo")))
        await startStudy(c, photo: true)
        await c.waitForStart()
        await c.waitForPhotoUpload()
        await c.cancelFlush()
        XCTAssertEqual(store.load().photos.count, 1)
        XCTAssertEqual(backend.count("attach_session_photo"), 0)
    }

    // MARK: 종료 확인 필요

    func testNeedsConfirmationOpensConfirmScreenAndConfirms() async {
        let c = makeController()
        backend.on("get_my_live_session", .json(Fixture.session(status: "needs_confirmation", category: "study", duration: nil)))
        await c.refresh()
        XCTAssertEqual(c.live?.phase, .needsConfirmation)
        XCTAssertEqual(c.route, .confirmEnd)
        // 한도(공부 4시간)보다 앞선 시각이 기본값
        let started = c.live!.startedAt!
        XCTAssertLessThan(c.confirmDate, started.addingTimeInterval(4 * 3600))
        XCTAssertGreaterThan(c.confirmDate, started)

        backend.on("confirm_end", .json(Fixture.session(status: "ended", duration: 12_000)))
        c.commitConfirmEnd()
        XCTAssertNil(c.live)
        await c.waitUntilIdle()
        XCTAssertEqual(backend.count("confirm_end"), 1)
        XCTAssertEqual(backend.lastParams("confirm_end")?["p_ended_at"], .string(ISODate.string(c.confirmDate)))
    }

    func testRefreshEndsLocalSessionWhenServerHasNone() async {
        let c = makeController()
        backend.on("start_session", .json(Fixture.session()))
        await startStudy(c)
        await c.waitUntilIdle()
        backend.on("get_my_live_session", .json(NSNull()))
        await c.refresh()
        XCTAssertNil(c.live)
    }

    func testPresentStartWhileLiveShowsAlertInsteadOfSecondSession() async {
        let c = makeController()
        backend.on("start_session", .json(Fixture.session()))
        await startStudy(c)
        await c.waitUntilIdle()
        c.presentStart(startRequest())
        XCTAssertEqual(c.route, .none)
        XCTAssertNotNil(c.alert)
    }

    func testStartScreenCannotStartWithoutCategory() async {
        let c = makeController()
        backend.on("list_threads", .json([Any]()))
        c.presentStart(startRequest())
        c.commitStart()
        XCTAssertNil(c.live)
        XCTAssertEqual(c.route, .start)
    }
    // MARK: 크루 고르기 (공개 대상이 크루일 때)

    private static let crewA = "cccccccc-0000-0000-0000-00000000000a"
    private static let crewB = "cccccccc-0000-0000-0000-00000000000b"

    private func crewJSON(_ id: String, _ name: String) -> [String: Any] {
        ["id": id, "name": name, "invite_code": "ABCD1234", "member_count": 3, "role": "member"]
    }

    private func openStart(_ c: SessionController, crews: [[String: Any]]) async {
        backend.on("list_threads", .json([Any]()))
        backend.on("list_my_crews", .json(crews))
        c.presentStart(startRequest())
        c.draft?.category = "study"
        await c.draft?.loadCrews(using: backend)
    }

    func testSingleCrewIsChosenAutomaticallyAndSentAsGroupID() async {
        let c = makeController()
        backend.on("start_session", .json(Fixture.session()))
        await openStart(c, crews: [crewJSON(Self.crewA, "스터디")])
        c.draft?.visibility = .crew
        XCTAssertEqual(c.draft?.resolvedGroupID, UUID(uuidString: Self.crewA))
        XCTAssertEqual(c.draft?.canStart, true)
        c.commitStart()
        await c.waitUntilIdle()
        let p = backend.lastParams("start_session")!
        XCTAssertEqual(p["p_visibility"], .string("crew"))
        XCTAssertEqual(p["p_group_id"], .string(Self.crewA))
    }

    func testSeveralCrewsRequireAChoice() async {
        let c = makeController()
        backend.on("start_session", .json(Fixture.session()))
        await openStart(c, crews: [crewJSON(Self.crewA, "스터디"), crewJSON(Self.crewB, "동아리")])
        c.draft?.visibility = .crew
        XCTAssertNil(c.draft?.resolvedGroupID)
        XCTAssertEqual(c.draft?.canStart, false)
        c.commitStart()
        XCTAssertNil(c.live)                                // 크루를 고르기 전에는 시작하지 않는다
        XCTAssertEqual(c.route, .start)

        c.draft?.groupID = UUID(uuidString: Self.crewB)
        c.commitStart()
        await c.waitUntilIdle()
        XCTAssertEqual(backend.lastParams("start_session")?["p_group_id"], .string(Self.crewB))
    }

    func testNoCrewsHidesCrewChoiceAndNonCrewSendsNullGroupID() async {
        let c = makeController()
        backend.on("start_session", .json(Fixture.session()))
        await openStart(c, crews: [])
        XCTAssertEqual(c.draft?.availableTargets, [.private, .friends])
        c.draft?.visibility = .friends
        c.commitStart()
        await c.waitUntilIdle()
        XCTAssertEqual(backend.lastParams("start_session")?["p_group_id"], .null)
    }

    // MARK: 종료 알림의 todo_id

    func testEndAfterRelaunchUsesTodoIDFromServerSession() async {
        let c = makeController()
        let todo = "dddddddd-0000-0000-0000-000000000001"
        backend.on("get_my_live_session", .json(Fixture.session(todoID: todo)))
        await c.refresh()                                   // 앱을 껐다 켠 뒤 서버에서 받은 세션
        XCTAssertEqual(c.live?.todoID, UUID(uuidString: todo))

        backend.on("end_session", .json(Fixture.session(status: "ended", outcome: "done", todoID: todo)))
        let received = expectation(description: "pondu.session.ended")
        let todoIDs = Locked<[String]>([])
        let token = NotificationCenter.default.addObserver(forName: Notification.Name("pondu.session.ended"), object: nil, queue: nil) { note in
            if let id = note.userInfo?["todo_id"] as? String { todoIDs.withValue { $0.append(id) } }
            received.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        c.presentEnd(); c.endDraft.choice = .done; c.commitEnd()
        await c.waitUntilIdle()
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(todoIDs.current, [todo])
    }
}
