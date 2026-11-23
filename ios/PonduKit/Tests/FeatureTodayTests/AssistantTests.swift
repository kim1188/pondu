import XCTest
import PonduCore
@testable import FeatureToday

private let proposalJSON = """
{"proposal_id":"dddddddd-0000-0000-0000-000000000001",
 "proposal":{"todos":[
    {"title":"DB 과제 1번","due_date":null,"due_time":null,"estimate_min":85,"category":"study"},
    {"title":"앱 로그인 수정","due_date":null,"due_time":null,"estimate_min":60,"category":"coding"}],
  "blocks":[
    {"todo_ref":"new:0","start":"2026-11-23T15:00:00+09:00","end":"2026-11-23T16:25:00+09:00"},
    {"todo_ref":"new:1","start":"2026-11-23T17:00:00+09:00","end":"2026-11-23T18:00:00+09:00"},
    {"todo_ref":"\(Fixture.todoA)","start":"2026-11-23T19:00:00+09:00","end":"2026-11-23T20:00:00+09:00"}],
  "done_todo_ids":["\(Fixture.todoB)"],"unscheduled":[],"questions":[],"message":"오늘 계획이에요."},
 "dropped":[{"rule":"overlap","detail":"강의와 겹쳐서 뺐어요"}]}
"""

final class AssistantStreamTests: XCTestCase {
    func testReducerAccumulatesDeltasThenProposal() {
        var state = AssistantStreamState()
        AssistantStream.reduce(&state, event: Fixture.sse("message_delta", #"{"text":"오늘은 "}"#))
        AssistantStream.reduce(&state, event: Fixture.sse("message_delta", #"{"text":"두 가지예요."}"#))
        AssistantStream.reduce(&state, event: Fixture.sse("ping", "{}"))
        XCTAssertEqual(state.message, "오늘은 두 가지예요.")
        XCTAssertTrue(state.receivedFirstDelta)
        XCTAssertNil(AssistantStream.envelope(from: state))
        AssistantStream.reduce(&state, event: Fixture.sse("proposal", proposalJSON))
        let env = AssistantStream.envelope(from: state)
        XCTAssertEqual(env?.proposal.todos.count, 2)
        XCTAssertEqual(env?.proposal.blocks.count, 3)
        XCTAssertEqual(env?.dropped.first?.rule, "overlap")
        XCTAssertEqual(env?.proposal.blocks[0].newTodoIndex, 0)
        XCTAssertNil(env?.proposal.blocks[2].newTodoIndex)
        XCTAssertNotNil(env?.proposal.blocks[0].startDate)
    }

    func testErrorEvent() {
        var state = AssistantStreamState()
        AssistantStream.reduce(&state, event: Fixture.sse("error", #"{"code":"quota_exceeded"}"#))
        XCTAssertEqual(state.errorCode, "quota_exceeded")
    }

    func testRequestBodyHasBusyIntervalsOnly() {
        let busy = [BusyInterval(start: Fixture.date("2026-11-23T05:00:00Z"), end: Fixture.date("2026-11-23T06:00:00Z"))]
        let body = AssistantModel.requestBody(kind: .planDay, text: "", now: Fixture.now, timeZone: Fixture.tz, busy: busy, session: nil)
        guard case .object(let o) = body else { return XCTFail() }
        XCTAssertEqual(o["kind"], .string("plan_day"))
        XCTAssertEqual(o["tz"], .string("Asia/Seoul"))
        XCTAssertEqual(o["session"], .null)
        guard case .array(let items)? = o["busy"], case .object(let first) = items[0] else { return XCTFail() }
        XCTAssertEqual(Set(first.keys), ["start", "end"])
    }

    func testRescheduleBodyCarriesSessionOutcome() {
        let signal = SessionEndSignal(todoID: Fixture.todoA, outcome: "more", note: "절반 했어요")
        let body = AssistantModel.requestBody(kind: .reschedule, text: "", now: Fixture.now, timeZone: Fixture.tz, busy: [], session: signal)
        guard case .object(let o) = body, case .object(let s)? = o["session"] else { return XCTFail() }
        XCTAssertEqual(s["outcome"], .string("more"))
        XCTAssertEqual(s["todo_id"], .string(Fixture.todoA.uuidString.lowercased()))
    }

    @MainActor func testEndToEndStreamShowsMessageThenProposalAndSavesNothing() async {
        let backend = StubBackend()
        backend.streamEvents = [Fixture.sse("message_delta", #"{"text":"정리했어요."}"#), Fixture.sse("proposal", proposalJSON)]
        let consent = MemoryConsent(); consent.hasConsented = true
        let today = Fixture.makeModel(backend: backend)
        await today.load()
        let model = AssistantModel(kind: .capture, text: "DB 과제 하고 로그인 고치기", today: today, consent: consent)
        model.send()
        await model.waitUntilDone()
        XCTAssertEqual(model.phase, .proposal)
        XCTAssertEqual(model.message, "정리했어요.")
        // 적용 전에는 쓰기 함수를 하나도 부르지 않는다.
        let writes = ["create_todo", "create_plan_block", "apply_proposal", "import_todos"]
        XCTAssertTrue(backend.calls.filter { writes.contains($0.name) }.isEmpty)
    }

    @MainActor func testStreamErrorFallsBackToManualInput() async {
        let backend = StubBackend()
        backend.streamEvents = [Fixture.sse("error", #"{"code":"assistant_unavailable"}"#)]
        let consent = MemoryConsent(); consent.hasConsented = true
        let today = Fixture.makeModel(backend: backend)
        let model = AssistantModel(kind: .capture, text: "과제하기", today: today, consent: consent)
        model.send()
        await model.waitUntilDone()
        XCTAssertEqual(model.phase, .failed(code: "assistant_unavailable"))
        XCTAssertEqual(model.manualDraft().title, "과제하기")
    }

    @MainActor func testConsentRequiredBeforeFirstUse() {
        let model = AssistantModel(kind: .planDay, today: Fixture.makeModel(), consent: MemoryConsent())
        XCTAssertEqual(model.phase, .needsConsent)
        XCTAssertFalse(model.canSend)
        model.acceptConsent()
        XCTAssertEqual(model.phase, .idle)
    }

    @MainActor func testEstimateNoteMentionsFactor() async {
        let backend = StubBackend()
        backend.streamEvents = [Fixture.sse("proposal", proposalJSON)]
        let consent = MemoryConsent(); consent.hasConsented = true
        let today = Fixture.makeModel(backend: backend)
        await today.load()            // 보정 배수 study 1.4
        let model = AssistantModel(kind: .capture, text: "x", today: today, consent: consent)
        model.send(); await model.waitUntilDone()
        let notes = model.estimateNotes()
        XCTAssertEqual(notes.count, 1)                     // coding은 배수가 없어 말하지 않는다
        XCTAssertTrue(notes[0].contains("1.4배"))
        XCTAssertTrue(notes[0].contains("85분"))
    }
}

final class ProposalSelectionTests: XCTestCase {
    var proposal: AssistantProposal {
        try! TodayCoding.decoder.decode(ProposalEnvelope.self, from: Data(proposalJSON.utf8)).proposal
    }

    func testSelectAllUsesNullIndexes() {
        let p = proposal
        let params = ProposalSelection(for: p).params(proposalID: UUID(), proposal: p)
        XCTAssertEqual(params["p_todo_indexes"], .null)
        XCTAssertEqual(params["p_block_indexes"], .null)
        XCTAssertEqual(params["p_apply_done"], .bool(true))
    }

    func testPartialApplySendsOnlyChosenIndexes() {
        let p = proposal
        var sel = ProposalSelection(for: p)
        sel.toggleBlock(1, in: p)          // new:1 예정 시간을 뺀다
        sel.toggleTodo(1, in: p)           // new:1 할 일도 뺀다
        sel.applyDone = false
        let params = sel.params(proposalID: UUID(), proposal: p)
        XCTAssertEqual(params["p_todo_indexes"], .array([.number(0)]))
        XCTAssertEqual(params["p_block_indexes"], .array([.number(0), .number(2)]))
        XCTAssertEqual(params["p_apply_done"], .bool(false))
    }

    func testRemovingTodoRemovesItsBlocks() {
        let p = proposal
        var sel = ProposalSelection(for: p)
        sel.toggleTodo(0, in: p)
        XCTAssertFalse(sel.blockIndexes.contains(0))
        XCTAssertTrue(sel.blockIndexes.contains(1))
    }

    func testSelectingBlockBringsItsNewTodo() {
        let p = proposal
        var sel = ProposalSelection(for: p)
        sel.toggleTodo(0, in: p)           // 할 일 0과 블록 0이 빠짐
        sel.toggleBlock(0, in: p)          // 블록 0을 다시 고르면
        XCTAssertTrue(sel.todoIndexes.contains(0))
    }

    func testEmptySelectionCannotApply() {
        let p = proposal
        var sel = ProposalSelection(for: p)
        sel.todoIndexes = []; sel.blockIndexes = []; sel.applyDone = false
        XCTAssertTrue(sel.isEmpty)
    }

    @MainActor func testApplyCallsServerWithSelectionAndReloads() async {
        let backend = StubBackend()
        backend.streamEvents = [Fixture.sse("proposal", proposalJSON)]
        backend.responses["apply_proposal"] = #"{"todos":[],"blocks":[]}"#
        let consent = MemoryConsent(); consent.hasConsented = true
        let today = Fixture.makeModel(backend: backend)
        let model = AssistantModel(kind: .planDay, today: today, consent: consent)
        model.send(); await model.waitUntilDone()
        model.selection?.toggleBlock(2, in: model.envelope!.proposal)
        await model.apply()
        XCTAssertEqual(model.phase, .applied)
        let call = backend.calls(named: "apply_proposal").first
        XCTAssertEqual(call?.params["p_block_indexes"], .array([.number(0), .number(1)]))
        XCTAssertFalse(backend.calls(named: "get_today").isEmpty)        // 적용 뒤 다시 불러온다
    }

    @MainActor func testAlreadyAppliedIsTreatedAsApplied() async {
        let backend = StubBackend()
        backend.streamEvents = [Fixture.sse("proposal", proposalJSON)]
        backend.failures["apply_proposal"] = BackendError(code: "proposal_already_applied")
        let consent = MemoryConsent(); consent.hasConsented = true
        let model = AssistantModel(kind: .planDay, today: Fixture.makeModel(backend: backend), consent: consent)
        model.send(); await model.waitUntilDone()
        await model.apply()
        XCTAssertEqual(model.phase, .applied)
    }
}

private let askJSON = """
{"proposal_id":"dddddddd-0000-0000-0000-000000000002",
 "proposal":{"todos":[{"title":"영어 단어","due_date":null,"due_time":null,"estimate_min":null,"category":null}],
  "blocks":[{"todo_ref":"new:0","start":"2026-11-23T21:00:00+09:00","end":"2026-11-23T21:30:00+09:00"}],
  "done_todo_ids":[],"unscheduled":[{"todo_ref":"\(Fixture.todoA)","reason":"자리가 없음"}],
  "estimate_asks":["new:0"],"questions":[],"message":"오늘 계획이에요."},
 "dropped":[],
 "availability":{"today":{"free_minutes":90,"largest_minutes":90,"slots":[]},
  "fit_checks":[{"todo_ref":"\(Fixture.todoA)","needed_minutes":180,"largest_today_minutes":90,
    "largest_before_due_minutes":null,"fits_within_days":2,"options":["partial_today","move_later","skip"],
    "partial_slot":{"start":"2026-11-23T21:30:00+09:00","end":"2026-11-23T23:00:00+09:00","minutes":90},
    "full_slot":{"start":"2026-11-24T08:00:00+09:00","end":"2026-11-24T11:00:00+09:00","minutes":180}}]}}
"""

private let adjustedJSON = """
{"proposal_id":"dddddddd-0000-0000-0000-000000000003",
 "proposal":{"todos":[{"title":"영어 단어","due_date":null,"due_time":null,"estimate_min":60,"category":null}],
  "blocks":[{"todo_ref":"new:0","start":"2026-11-23T21:00:00+09:00","end":"2026-11-23T22:00:00+09:00"}],
  "done_todo_ids":[],"unscheduled":[],"estimate_asks":[],"questions":[],"message":"오늘 계획이에요."},
 "dropped":[],"availability":{"today":{"free_minutes":60,"largest_minutes":60,"slots":[]},"fit_checks":[]},
 "replaces":"dddddddd-0000-0000-0000-000000000002","estimate_updates":[],"rejected":[]}
"""

final class EstimateAskTests: XCTestCase {
    func testOldResponseWithoutNewFieldsStillDecodes() {
        var state = AssistantStreamState()
        AssistantStream.reduce(&state, event: Fixture.sse("proposal", proposalJSON))
        let env = AssistantStream.envelope(from: state)
        XCTAssertEqual(env?.proposal.estimateAsks, [])
        XCTAssertNil(env?.availability)
        XCTAssertEqual(env?.estimateUpdates, [])
    }

    func testDecodesAsksAndFitChecks() {
        var state = AssistantStreamState()
        AssistantStream.reduce(&state, event: Fixture.sse("proposal", askJSON))
        let env = AssistantStream.envelope(from: state)
        XCTAssertEqual(env?.proposal.estimateAsks, ["new:0"])
        XCTAssertEqual(env?.availability?.today.freeMinutes, 90)
        XCTAssertEqual(env?.availability?.fitChecks.first?.options, ["partial_today", "move_later", "skip"])
        XCTAssertEqual(env?.availability?.fitChecks.first?.partialSlot?.minutes, 90)
    }

    func testAdjustBody() {
        let id = UUID(uuidString: "dddddddd-0000-0000-0000-000000000002")!
        let body = AssistantModel.adjustBody(proposalID: id, estimates: [("new:0", 60)], fits: [("t", "move_later")], timeZone: Fixture.tz, busy: [])
        guard case .object(let o) = body else { return XCTFail() }
        XCTAssertEqual(o["kind"], .string("adjust"))
        XCTAssertEqual(o["proposal_id"], .string("dddddddd-0000-0000-0000-000000000002"))
        XCTAssertEqual(o["estimates"], .array([.object(["todo_ref": .string("new:0"), "minutes": .number(60)])]))
        XCTAssertEqual(o["fits"], .array([.object(["todo_ref": .string("t"), "option": .string("move_later")])]))
    }

    @MainActor
    func testAskThenSkipKeepsThirtyMinutesAndSendsNothing() async {
        let backend = StubBackend()
        backend.streamEvents = [Fixture.sse("proposal", askJSON)]
        let consent = MemoryConsent(); consent.hasConsented = true
        let model = AssistantModel(kind: .planDay, today: Fixture.makeModel(backend: backend), consent: consent)
        model.send()
        await model.waitUntilDone()
        XCTAssertEqual(model.pendingAsks, ["new:0"])
        XCTAssertNotNil(model.askDeadline)
        backend.lastStreamBody = nil
        model.skipEstimate("new:0")
        XCTAssertEqual(model.pendingAsks, [])
        XCTAssertNil(model.askDeadline)
        XCTAssertNil(backend.lastStreamBody, "건너뛰면 서버에 아무것도 보내지 않는다")
        XCTAssertEqual(model.envelope?.proposal.blocks.first?.end, "2026-11-23T21:30:00+09:00")
    }

    @MainActor
    func testTimeoutEndsAsking() async {
        let backend = StubBackend()
        backend.streamEvents = [Fixture.sse("proposal", askJSON)]
        let consent = MemoryConsent(); consent.hasConsented = true
        let model = AssistantModel(kind: .planDay, today: Fixture.makeModel(backend: backend), consent: consent)
        model.send()
        await model.waitUntilDone()
        model.expireAsks()
        XCTAssertEqual(model.pendingAsks, [])
        XCTAssertEqual(model.phase, .proposal)
    }

    @MainActor
    func testAnswerReplacesProposal() async {
        let backend = StubBackend()
        backend.streamEvents = [Fixture.sse("proposal", askJSON)]
        let consent = MemoryConsent(); consent.hasConsented = true
        let model = AssistantModel(kind: .planDay, today: Fixture.makeModel(backend: backend), consent: consent)
        model.send()
        await model.waitUntilDone()
        backend.streamEvents = [Fixture.sse("proposal", adjustedJSON)]
        await model.answerEstimate("new:0", minutes: 60)
        guard case .object(let o)? = backend.lastStreamBody else { return XCTFail() }
        XCTAssertEqual(o["kind"], .string("adjust"))
        XCTAssertEqual(model.envelope?.proposalId, UUID(uuidString: "dddddddd-0000-0000-0000-000000000003"))
        XCTAssertEqual(model.envelope?.proposal.blocks.first?.end, "2026-11-23T22:00:00+09:00")
        XCTAssertEqual(model.pendingAsks, [])
    }

    @MainActor
    func testSkipFitHidesCheckWithoutRequest() async {
        let backend = StubBackend()
        backend.streamEvents = [Fixture.sse("proposal", askJSON)]
        let consent = MemoryConsent(); consent.hasConsented = true
        let model = AssistantModel(kind: .planDay, today: Fixture.makeModel(backend: backend), consent: consent)
        model.send()
        await model.waitUntilDone()
        XCTAssertEqual(model.fitChecks.count, 1)
        backend.lastStreamBody = nil
        await model.chooseFit(Fixture.todoA.uuidString, option: "skip")
        XCTAssertNil(backend.lastStreamBody)
    }
}
