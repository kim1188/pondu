import XCTest
import PonduCore
@testable import FeatureToday

@MainActor
final class TodayModelTests: XCTestCase {
    func testLoadShowsCachedSnapshotBeforeServerAnswers() async {
        let store = MemoryStore()
        let backend = StubBackend()
        let model1 = Fixture.makeModel(backend: backend, store: store)
        await model1.load()
        XCTAssertNotNil(store.saved)

        let failing = StubBackend()
        failing.failures["get_today"] = BackendError(code: "network")
        let model2 = Fixture.makeModel(backend: failing, store: store)
        await model2.load()
        XCTAssertEqual(model2.snapshot?.todos.count, 2)       // 저장분이 그대로 남는다
        XCTAssertFalse(model2.loadFailed)
        XCTAssertNotNil(model2.errorMessage)
    }

    func testLoadFailureWithoutCacheShowsError() async {
        let backend = StubBackend(); backend.failures["get_today"] = BackendError(code: "timeout")
        let model = Fixture.makeModel(backend: backend)
        await model.load()
        XCTAssertTrue(model.loadFailed)
    }

    func testLoadUsesOneServerFunctionForTheScreen() async {
        let backend = StubBackend()
        await Fixture.makeModel(backend: backend).load()
        XCTAssertEqual(backend.calls.map(\.name), ["get_today"])
        XCTAssertEqual(backend.calls[0].params["p_day"], .string("2026-11-23"))
        XCTAssertEqual(backend.calls[0].params["p_tz"], .string("Asia/Seoul"))
    }

    func testStartableAndStartCallsPresentStartWithoutWaitingForServer() async {
        let sessions = FakeSessions()
        let backend = StubBackend()
        let model = Fixture.makeModel(backend: backend, sessions: sessions)
        await model.load()
        XCTAssertEqual(model.startable.count, 1)
        let before = backend.calls.count
        model.start(block: model.startable[0])
        XCTAssertEqual(sessions.requests.count, 1)
        XCTAssertEqual(sessions.requests[0].todoID, Fixture.todoA)
        XCTAssertEqual(sessions.requests[0].planBlockID, Fixture.block1)
        XCTAssertEqual(sessions.requests[0].title, "DB 과제")
        XCTAssertEqual(backend.calls.count, before)            // 서버 호출 없이 화면부터
    }

    func testToggleDoneIsImmediateAndRollsBackOnFailure() async {
        let backend = StubBackend()
        backend.failures["set_todo_status"] = BackendError(code: "network")
        let model = Fixture.makeModel(backend: backend)
        await model.load()
        let todo = model.snapshot!.todos[0]
        model.toggleDone(todo)
        XCTAssertEqual(model.snapshot?.todos[0].status, "done")   // 누르는 즉시
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.snapshot?.todos[0].status, "open")   // 실패해서 되돌림
        XCTAssertNotNil(model.errorMessage)
    }

    func testToggleDoneSuccessSendsStatus() async {
        let backend = StubBackend()
        let model = Fixture.makeModel(backend: backend)
        await model.load()
        model.toggleDone(model.snapshot!.todos[0])
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(backend.calls(named: "set_todo_status").first?.params["p_status"], .string("done"))
        XCTAssertEqual(model.snapshot?.todos[0].status, "done")
    }

    func testAddTodoReplacesTempWithServerRowAndRemovesOnFailure() async {
        let backend = StubBackend()
        let newID = UUID()
        backend.responses["create_todo"] = #"{"id":"\#(newID)","title":"새 일","status":"open","due_has_time":false}"#
        let model = Fixture.makeModel(backend: backend)
        await model.load()
        var draft = TodayModel.TodoDraft(); draft.title = " 새 일 "
        let ok = await model.addTodo(draft)
        XCTAssertTrue(ok)
        XCTAssertTrue(model.snapshot!.todos.contains { $0.id == newID })
        XCTAssertEqual(model.snapshot!.todos.count, 3)

        backend.failures["create_todo"] = BackendError(code: "invalid_input")
        let ok2 = await model.addTodo(draft)
        XCTAssertFalse(ok2)
        XCTAssertEqual(model.snapshot!.todos.count, 3)
    }

    func testRemainingSortedByDueThenUndated() async {
        let model = Fixture.makeModel()
        await model.load()
        XCTAssertEqual(model.remaining.map(\.title), ["DB 과제", "운동"])
    }

    func testRescheduleHintOnlyForMoreOutcome() {
        let model = Fixture.makeModel()
        model.receiveSessionEnd(SessionEndSignal(todoID: nil, outcome: "done", note: nil))
        XCTAssertNil(model.rescheduleHint)
        model.receiveSessionEnd(SessionEndSignal(todoID: Fixture.todoA, outcome: "more", note: nil))
        XCTAssertNotNil(model.rescheduleHint)
    }

    func testDeleteBlockRollsBackOnFailure() async {
        let backend = StubBackend()
        backend.failures["delete_plan_block"] = BackendError(code: "forbidden")
        let model = Fixture.makeModel(backend: backend)
        await model.load()
        model.deleteBlock(model.snapshot!.blocks[0])
        XCTAssertTrue(model.snapshot!.blocks.isEmpty)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.snapshot!.blocks.count, 1)
    }

    func testEstimateNoteSkippedNearOne() {
        XCTAssertNil(TodayLogic.estimateNote(categoryRaw: "study", estimateMin: 60, factors: ["study": 1.02]))
        XCTAssertNil(TodayLogic.estimateNote(categoryRaw: "study", estimateMin: 60, factors: [:]))
    }
}
