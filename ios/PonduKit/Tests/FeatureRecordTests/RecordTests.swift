import XCTest
import PonduCore
@testable import FeatureRecord

final class HeatmapTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testRangeStartsOnMondayWeeksBack() {
        // 2026-11-22는 일요일. 이번 주는 월요일인 11-16에 시작한다.
        let r = Heatmap.range(today: date(2026, 11, 22), weeks: 4, calendar: cal)
        XCTAssertEqual(Heatmap.dayString(r.from, calendar: cal), "2026-10-26")   // 3주 전 월요일
        XCTAssertEqual(Heatmap.dayString(r.to, calendar: cal), "2026-11-22")
    }

    func testColumnsMarkOnlyDaysWithRecords() {
        let days = [
            RecordSummary.DayStat(day: "2026-11-20", seconds: 3600, sessionCount: 1),
            RecordSummary.DayStat(day: "2026-11-21", seconds: 10, sessionCount: 5),
        ]
        let cols = Heatmap.columns(days: days, today: date(2026, 11, 22), weeks: 2, calendar: cal)
        XCTAssertEqual(cols.count, 2)
        XCTAssertTrue(cols.allSatisfy { $0.count == 7 })
        let flat = cols.flatMap { $0 }
        XCTAssertEqual(flat.first { $0.day == "2026-11-20" }?.level, 1)
        XCTAssertEqual(flat.first { $0.day == "2026-11-21" }?.level, 3)   // 세션 수만 보고 3단계까지
        XCTAssertEqual(flat.first { $0.day == "2026-11-19" }?.level, 0)
    }

    func testFutureDaysInCurrentWeekAreBlank() {
        // 2026-11-18은 수요일 → 같은 주의 목~일은 칸만 있고 날짜 없음
        let cols = Heatmap.columns(days: [], today: date(2026, 11, 18), weeks: 1, calendar: cal)
        XCTAssertEqual(cols[0].compactMap(\.day).count, 3)
        XCTAssertNil(cols[0][6].day)
    }

    func testTimeDoesNotChangeShade() {
        // 시간이 길다고 진해지지 않는다(시간 많은 사람을 올리지 않는다)
        let a = Heatmap.columns(days: [.init(day: "2026-11-20", seconds: 60, sessionCount: 1)], today: date(2026, 11, 22), weeks: 1, calendar: cal)
        let b = Heatmap.columns(days: [.init(day: "2026-11-20", seconds: 36_000, sessionCount: 1)], today: date(2026, 11, 22), weeks: 1, calendar: cal)
        XCTAssertEqual(a, b)
    }
}

final class RecordLabelTests: XCTestCase {
    private func session(status: String = "ended", capture: String = "no_photo", corrected: Bool = false, offline: Bool = false) throws -> RecordSession {
        var obj = RecordFixture.session(1, status: status, captureMode: capture, endCorrected: corrected, offline: offline)
        obj["thread_id"] = NSNull()
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try RecordStubBackend.decoder.decode(RecordSession.self, from: data)
    }

    func testCaptureModeWording() throws {
        XCTAssertEqual(RecordLabels.labels(for: try session(capture: "in_app_photo")), ["앱 촬영 첨부"])
        XCTAssertEqual(RecordLabels.labels(for: try session(capture: "no_photo")), ["사진 없는 기록"])
    }

    func testCorrectedAndOfflineAndNeedsConfirmation() throws {
        let labels = RecordLabels.labels(for: try session(status: "needs_confirmation", corrected: true, offline: true))
        XCTAssertEqual(labels, ["종료 확인 필요", "사진 없는 기록", "나중에 정정함", "오프라인 시작"])
    }

    func testNoLabelSaysCertified() throws {
        let all = try [
            session(capture: "in_app_photo"), session(corrected: true), session(offline: true), session(status: "live"),
        ].flatMap { RecordLabels.labels(for: $0) }
        XCTAssertFalse(all.contains { $0.contains("인증") })
    }

    func testDurationWording() {
        XCTAssertEqual(RecordLabels.duration(30), "1분 미만")
        XCTAssertEqual(RecordLabels.duration(37 * 60), "37분")
        XCTAssertEqual(RecordLabels.duration(3600), "1시간")
        XCTAssertEqual(RecordLabels.duration(3600 + 5 * 60), "1시간 5분")
    }
}

@MainActor
final class RecordModelTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }()
    private let fixedNow = Date(timeIntervalSince1970: 1_795_000_000)

    private func model(_ backend: RecordStubBackend, cache: RecordCaching = InMemoryRecordCache()) -> RecordModel {
        let now = fixedNow
        return RecordModel(backend: backend, cache: cache, now: { now }, calendar: cal)
    }

    func testLoadFetchesSummaryAndFirstPageOnceEach() async {
        let b = RecordStubBackend()
        b.on("get_record_summary", .json(RecordFixture.summary))
        b.on("list_my_sessions", .json(RecordFixture.page(0..<20, next: "c1")))
        let m = model(b)
        await m.load()
        XCTAssertEqual(b.calls("get_record_summary").count, 1)
        XCTAssertEqual(b.calls("list_my_sessions").count, 1)
        XCTAssertEqual(m.summary?.byCategory.first?.category, "study")
        XCTAssertEqual(m.sessions.items.count, 20)
        XCTAssertEqual(m.sessions.nextCursor, "c1")
        // 서버 인자: 20개, 커서 없음, 시간대
        let p = b.calls("list_my_sessions")[0].params
        XCTAssertEqual(p["p_limit"], .number(20))
        XCTAssertEqual(p["p_cursor"], .null)
        XCTAssertEqual(b.calls("get_record_summary")[0].params["p_tz"], .string("Asia/Seoul"))
    }

    func testLoadMoreUsesCursorAndDedupes() async {
        let b = RecordStubBackend()
        b.on("get_record_summary", .json(RecordFixture.summary))
        b.on("list_my_sessions", .json(RecordFixture.page(0..<20, next: "c1")))
        b.on("list_my_sessions", .json(RecordFixture.page(15..<30, next: nil)))   // 일부 겹침
        let m = model(b)
        await m.load()
        await m.sessions.loadMoreIfNeeded(current: m.sessions.items[19])
        XCTAssertEqual(b.calls("list_my_sessions")[1].params["p_cursor"], .string("c1"))
        XCTAssertEqual(m.sessions.items.count, 30)
        XCTAssertNil(m.sessions.nextCursor)
        // 끝났으면 더 요청하지 않는다
        await m.sessions.loadMoreIfNeeded(current: m.sessions.items[29])
        XCTAssertEqual(b.calls("list_my_sessions").count, 2)
    }

    func testRowFarFromEndDoesNotLoadMore() async {
        let b = RecordStubBackend()
        b.on("get_record_summary", .json(RecordFixture.summary))
        b.on("list_my_sessions", .json(RecordFixture.page(0..<20, next: "c1")))
        let m = model(b)
        await m.load()
        await m.sessions.loadMoreIfNeeded(current: m.sessions.items[0])
        XCTAssertEqual(b.calls("list_my_sessions").count, 1)
    }

    func testCachedValuesShownWhenServerFails() async {
        let cache = InMemoryRecordCache()
        let ok = RecordStubBackend()
        ok.on("get_record_summary", .json(RecordFixture.summary))
        ok.on("list_my_sessions", .json(RecordFixture.page(0..<20, next: "c1")))
        await model(ok, cache: cache).load()

        let down = RecordStubBackend()
        down.on("get_record_summary", .error(BackendError(code: "network")))
        down.on("list_my_sessions", .error(BackendError(code: "network")))
        let m = model(down, cache: cache)
        await m.load()
        XCTAssertNotNil(m.summary)                 // 저장해 둔 값으로 그린다
        XCTAssertEqual(m.sessions.items.count, 20)
        XCTAssertNil(m.errorCode)                  // 저장분이 있으면 오류 화면을 띄우지 않는다
    }

    func testErrorShownWhenNothingCached() async {
        let b = RecordStubBackend()
        b.on("get_record_summary", .error(BackendError(code: "timeout")))
        b.on("list_my_sessions", .error(BackendError(code: "timeout")))
        let m = model(b)
        await m.load()
        XCTAssertNil(m.summary)
        XCTAssertEqual(m.errorCode, "timeout")
    }

    func testThreadFilterIsPassedToServer() async {
        let b = RecordStubBackend()
        b.on("list_my_sessions", .json(RecordFixture.page(0..<3, next: nil)))
        let tid = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
        let list = SessionListModel(backend: b, threadID: tid)
        await list.reload()
        XCTAssertEqual(b.calls("list_my_sessions")[0].params["p_thread_id"], .string("bbbbbbbb-0000-0000-0000-000000000001"))
        XCTAssertEqual(list.items.count, 3)
    }

    func testRefreshReplacesCachedWithServerValues() async {
        let cache = InMemoryRecordCache()
        let first = RecordStubBackend()
        first.on("get_record_summary", .json(RecordFixture.summary))
        first.on("list_my_sessions", .json(RecordFixture.page(0..<20, next: "c1")))
        await model(first, cache: cache).load()

        let second = RecordStubBackend()
        second.on("get_record_summary", .json(["days": [Any](), "by_category": [Any](), "threads": [Any]()]))
        second.on("list_my_sessions", .json(RecordFixture.page(100..<102, next: nil)))
        let m = model(second, cache: cache)
        await m.load()
        XCTAssertEqual(m.sessions.items.count, 2)
        XCTAssertEqual(m.summary?.byCategory.count, 0)
        XCTAssertFalse(m.isShowingCached)
    }
}
