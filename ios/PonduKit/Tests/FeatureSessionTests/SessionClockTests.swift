import XCTest
@testable import FeatureSession

final class SessionClockTests: XCTestCase {
    func testFormulaSubtractsPausedSeconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(3_600)
        XCTAssertEqual(SessionClock.formula(startedAt: start, pausedAt: nil, pausedSeconds: 600, now: now), 3_000, accuracy: 0.001)
    }

    func testFormulaFreezesAtPausedAt() {
        let start = Date(timeIntervalSince1970: 1_000)
        let pausedAt = start.addingTimeInterval(1_800)
        let now = start.addingTimeInterval(9_999)
        XCTAssertEqual(SessionClock.formula(startedAt: start, pausedAt: pausedAt, pausedSeconds: 300, now: now), 1_500, accuracy: 0.001)
    }

    func testFormulaNeverNegative() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(SessionClock.formula(startedAt: start, pausedAt: nil, pausedSeconds: 50, now: start), 0)
    }

    func testRunningClockAdvancesWithMonotonicTimeOnly() throws {
        let snap = try snapshot(status: "live", duration: 120)
        let clock = SessionClock(snapshot: snap, uptime: 1_000)
        XCTAssertEqual(clock.elapsed(at: 1_000), 120, accuracy: 0.001)
        XCTAssertEqual(clock.elapsed(at: 1_030), 150, accuracy: 0.001)
        // Date를 받는 경로가 없으므로 기기 시각을 바꿔도 값이 달라질 수 없다.
    }

    func testPausedClockIsFrozen() throws {
        let snap = try snapshot(status: "paused", duration: 0, pausedAt: "2026-11-22T01:30:00Z", pausedSeconds: 120)
        let clock = SessionClock(snapshot: snap, uptime: 50)
        XCTAssertFalse(clock.running)
        XCTAssertEqual(clock.elapsed(at: 50), 1_680, accuracy: 0.001)   // 30분 - 2분
        XCTAssertEqual(clock.elapsed(at: 5_000), 1_680, accuracy: 0.001)
    }

    func testPauseThenResumeContinuesFromFrozenValue() {
        let c = SessionClock(base: 10, anchorUptime: 100, running: true)
        let paused = c.paused(at: 130)           // 40초
        XCTAssertEqual(paused.elapsed(at: 999), 40, accuracy: 0.001)
        let resumed = paused.resumed(at: 200)
        XCTAssertEqual(resumed.elapsed(at: 215), 55, accuracy: 0.001)
    }

    func testBackwardsMonotonicNeverGoesNegative() {
        let c = SessionClock(base: 5, anchorUptime: 100, running: true)
        XCTAssertEqual(c.elapsed(at: 50), 5, accuracy: 0.001)
    }

    func testFormat() {
        XCTAssertEqual(ElapsedFormat.clock(7), "0:07")
        XCTAssertEqual(ElapsedFormat.clock(37 * 60 + 5), "37:05")
        XCTAssertEqual(ElapsedFormat.clock(3_600 + 2 * 60 + 9), "1:02:09")
    }

    func testCategoryLimits() {
        XCTAssertEqual(SessionRules.limitHours(for: "study"), 4)
        XCTAssertEqual(SessionRules.limitHours(for: "exercise"), 3)
        XCTAssertEqual(SessionRules.limitHours(for: "parttime"), 10)
        XCTAssertEqual(SessionRules.limitHours(for: "venture_research_intern"), 10)
    }

    private func snapshot(status: String, duration: Int, pausedAt: String? = nil, pausedSeconds: Int = 0) throws -> SessionSnapshot {
        let obj = Fixture.session(status: status, pausedAt: pausedAt, pausedSeconds: pausedSeconds, duration: duration)
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try StubBackend.decoder.decode(SessionSnapshot.self, from: data)
    }
}
