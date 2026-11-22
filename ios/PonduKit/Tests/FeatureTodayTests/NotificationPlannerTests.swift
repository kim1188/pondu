import XCTest
@testable import FeatureToday

final class NotificationPlannerTests: XCTestCase {
    func block(_ id: Int, start: String, status: String = "planned", todo: UUID? = Fixture.todoA) -> TodayBlock {
        TodayBlock(id: UUID(uuidString: "bbbbbbbb-0000-0000-0000-00000000000\(id)")!, todoId: todo,
                   startAt: Fixture.date(start), endAt: Fixture.date(start).addingTimeInterval(3600), status: status)
    }
    let todos = [TodayTodo(id: Fixture.todoA, title: "DB 과제"), TodayTodo(id: Fixture.todoB, title: "운동", status: "done")]

    func testOnlyFuturePlannedBlocksOfOpenTodos() {
        let blocks = [
            block(1, start: "2026-11-23T05:00:00Z"),                       // 미래
            block(2, start: "2026-11-23T00:00:00Z"),                       // 이미 지남(KST 09:00 < now 10:00)
            block(3, start: "2026-11-23T06:00:00Z", status: "started"),    // 이미 시작
            block(4, start: "2026-11-23T07:00:00Z", todo: Fixture.todoB),  // 끝낸 할 일
        ]
        let plans = NotificationPlanner.plan(blocks: blocks, todos: todos, now: Fixture.now)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].body, "DB 과제")
        XCTAssertEqual(plans[0].fireDate, Fixture.date("2026-11-23T05:00:00Z"))
    }

    func testSortedAndLimited() {
        let blocks = (1...5).reversed().map { block($0, start: "2026-11-23T0\($0 + 1):00:00Z") }
        let plans = NotificationPlanner.plan(blocks: blocks, todos: todos, now: Fixture.now, limit: 3)
        XCTAssertEqual(plans.count, 3)
        XCTAssertEqual(plans.map(\.fireDate), plans.map(\.fireDate).sorted())
    }

    func testMovedBlockKeepsIdentifierSoNotificationIsReplaced() {
        let a = NotificationPlanner.plan(blocks: [block(1, start: "2026-11-23T05:00:00Z")], todos: todos, now: Fixture.now)
        let b = NotificationPlanner.plan(blocks: [block(1, start: "2026-11-23T08:00:00Z")], todos: todos, now: Fixture.now)
        XCTAssertEqual(a[0].identifier, b[0].identifier)
        XCTAssertNotEqual(a[0].fireDate, b[0].fireDate)
    }

    func testStaleIdentifiersOnlyInsideCoveredRange() {
        let range = DateInterval(start: Fixture.date("2026-11-22T15:00:00Z"), end: Fixture.date("2026-11-23T15:00:00Z"))
        let keep = NotificationPlanner.plan(blocks: [block(1, start: "2026-11-23T05:00:00Z")], todos: todos, now: Fixture.now)
        let pending: [(id: String, fire: Date?)] = [
            (keep[0].identifier, Fixture.date("2026-11-23T05:00:00Z")),                          // 유지
            (NotificationPlanner.identifier(for: UUID()), Fixture.date("2026-11-23T06:00:00Z")),  // 범위 안인데 사라진 블록 → 지움
            (NotificationPlanner.identifier(for: UUID()), Fixture.date("2026-11-25T06:00:00Z")),  // 범위 밖 → 건드리지 않음
            ("other.app.notification", Fixture.date("2026-11-23T06:00:00Z")),                    // 남의 알림
        ]
        let stale = NotificationPlanner.staleIdentifiers(pending: pending, keep: keep, covering: range)
        XCTAssertEqual(stale.count, 1)
        XCTAssertEqual(stale[0], pending[1].id)
    }

    @MainActor func testMovingBlockResyncsNotifications() async {
        let backend = StubBackend()
        backend.responses["update_plan_block"] = """
        {"id":"\(Fixture.block1)","todo_id":"\(Fixture.todoA)","start_at":"2026-11-23T08:00:00Z","end_at":"2026-11-23T09:00:00Z","locked":false,"origin":"user","status":"planned"}
        """
        let notifier = FakeNotifier()
        let model = Fixture.makeModel(backend: backend, notifier: notifier)
        await model.load()
        let block = model.snapshot!.blocks[0]
        let before = notifier.synced.count
        let ok = await model.moveBlock(block, start: Fixture.date("2026-11-23T08:00:00Z"), end: Fixture.date("2026-11-23T09:00:00Z"))
        XCTAssertTrue(ok)
        XCTAssertEqual(notifier.synced.count, before + 1)
        XCTAssertEqual(notifier.synced.last?.first?.fireDate, Fixture.date("2026-11-23T08:00:00Z"))
    }
}
