import XCTest
import PonduCore
@testable import FeatureToday

final class BusyTimeTests: XCTestCase {
    let window = DateInterval(start: Fixture.date("2026-11-22T15:00:00Z"), end: Fixture.date("2026-11-23T15:00:00Z")) // KST 11/23 하루

    func testMergesOverlappingAndTouchingEvents() {
        let evs = [
            Fixture.event("강의", "2026-11-23T01:00:00Z", "2026-11-23T02:00:00Z"),
            Fixture.event("겹침", "2026-11-23T01:30:00Z", "2026-11-23T03:00:00Z"),
            Fixture.event("맞닿음", "2026-11-23T03:00:00Z", "2026-11-23T04:00:00Z"),
            Fixture.event("저녁", "2026-11-23T09:00:00Z", "2026-11-23T10:00:00Z"),
        ]
        let busy = BusyTime.intervals(from: evs, within: window)
        XCTAssertEqual(busy.count, 2)
        XCTAssertEqual(busy[0].start, Fixture.date("2026-11-23T01:00:00Z"))
        XCTAssertEqual(busy[0].end, Fixture.date("2026-11-23T04:00:00Z"))
    }

    func testAllDayAndFreeEventsAreNotBusy() {
        let evs = [
            Fixture.event("공휴일", "2026-11-22T15:00:00Z", "2026-11-23T15:00:00Z", allDay: true),
            Fixture.event("한가함", "2026-11-23T01:00:00Z", "2026-11-23T02:00:00Z", free: true),
        ]
        XCTAssertTrue(BusyTime.intervals(from: evs, within: window).isEmpty)
    }

    func testClipsToWindowAndDropsOutside() {
        let evs = [
            Fixture.event("자정 걸침", "2026-11-23T14:00:00Z", "2026-11-23T17:00:00Z"),
            Fixture.event("어제", "2026-11-21T01:00:00Z", "2026-11-21T02:00:00Z"),
        ]
        let busy = BusyTime.intervals(from: evs, within: window)
        XCTAssertEqual(busy.count, 1)
        XCTAssertEqual(busy[0].end, window.end)
    }

    func testPayloadHasOnlyStartAndEnd() {
        let evs = [Fixture.event("비밀 면접", "2026-11-23T01:00:00Z", "2026-11-23T02:00:00Z")]
        let payload = BusyTime.payload(BusyTime.intervals(from: evs, within: window))
        guard case .array(let items) = payload, case .object(let obj) = items[0] else { return XCTFail("모양이 다름") }
        XCTAssertEqual(Set(obj.keys), ["start", "end"])
        let data = try! JSONEncoder().encode(payload)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("비밀"))
    }

    func testConflicts() {
        let busy = [BusyInterval(start: Fixture.date("2026-11-23T01:00:00Z"), end: Fixture.date("2026-11-23T02:00:00Z"))]
        XCTAssertEqual(BusyTime.conflicts(DateInterval(start: Fixture.date("2026-11-23T01:30:00Z"), end: Fixture.date("2026-11-23T03:00:00Z")), with: busy).count, 1)
        XCTAssertTrue(BusyTime.conflicts(DateInterval(start: Fixture.date("2026-11-23T02:00:00Z"), end: Fixture.date("2026-11-23T03:00:00Z")), with: busy).isEmpty)
    }

    @MainActor func testAssistantRequestBusyComesFromCalendarWithoutTitles() async {
        let cal = FakeCalendar()
        cal.stored = [Fixture.event("치과", "2026-11-23T05:00:00Z", "2026-11-23T06:00:00Z")]
        let model = Fixture.makeModel(calendar: cal)
        let busy = await model.busyForAssistant()
        XCTAssertEqual(busy.count, 1)
    }

    @MainActor func testNoBusyWhenCalendarDenied() async {
        let cal = FakeCalendar(); cal.access = .denied
        cal.stored = [Fixture.event("치과", "2026-11-23T05:00:00Z", "2026-11-23T06:00:00Z")]
        let busy = await Fixture.makeModel(calendar: cal).busyForAssistant()
        XCTAssertTrue(busy.isEmpty)
    }
}
