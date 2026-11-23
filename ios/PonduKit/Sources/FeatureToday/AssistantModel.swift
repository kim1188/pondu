import Foundation
import Observation
import UserNotifications
import PonduCore

// MARK: - 제안 모양 (assistant/core/schema.mjs 와 같은 필드)

struct ProposalTodo: Codable, Hashable, Sendable {
    var title: String
    var dueDate: String?
    var dueTime: String?
    var estimateMin: Int?
    var category: String?
}

struct ProposalBlock: Codable, Hashable, Sendable {
    var todoRef: String
    var start: String
    var end: String

    var startDate: Date? { TodayISO.parse(start) }
    var endDate: Date? { TodayISO.parse(end) }
    /// `new:N` 이면 N, 아니면 nil(이미 있는 할 일).
    var newTodoIndex: Int? {
        guard todoRef.hasPrefix("new:") else { return nil }
        return Int(todoRef.dropFirst(4))
    }
}

struct ProposalUnscheduled: Codable, Hashable, Sendable { var todoRef: String; var reason: String }

struct AssistantProposal: Codable, Hashable, Sendable {
    var todos: [ProposalTodo]
    var blocks: [ProposalBlock]
    var doneTodoIds: [String]
    var unscheduled: [ProposalUnscheduled]
    var questions: [String]
    var message: String
    /// 예상 시간이 없어 30분으로 잡아 둔 일(`new:N` 또는 할 일 id). 앱이 얼마나 걸릴지 묻는다.
    var estimateAsks: [String] = []

    var isEmpty: Bool { todos.isEmpty && blocks.isEmpty && doneTodoIds.isEmpty }
}

extension AssistantProposal {
    // estimate_asks 가 없는 예전 응답도 읽는다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        todos = try c.decode([ProposalTodo].self, forKey: .todos)
        blocks = try c.decode([ProposalBlock].self, forKey: .blocks)
        doneTodoIds = try c.decode([String].self, forKey: .doneTodoIds)
        unscheduled = try c.decode([ProposalUnscheduled].self, forKey: .unscheduled)
        questions = try c.decode([String].self, forKey: .questions)
        message = try c.decode(String.self, forKey: .message)
        estimateAsks = try c.decodeIfPresent([String].self, forKey: .estimateAsks) ?? []
    }
}

// MARK: - 가용 시간 (assistant/core/availability.mjs 가 계산해 붙인다)

struct AvailabilitySlot: Codable, Hashable, Sendable {
    var start: String
    var end: String
    var minutes: Int
    var startDate: Date? { TodayISO.parse(start) }
    var endDate: Date? { TodayISO.parse(end) }
}

/// 다 들어가지 않아 시간을 못 잡은 일 하나의 점검 결과.
struct FitCheck: Codable, Hashable, Sendable {
    var todoRef: String
    var neededMinutes: Int
    var largestTodayMinutes: Int
    var largestBeforeDueMinutes: Int?
    var fitsWithinDays: Int?
    /// partial_today(오늘 들어가는 만큼만) | move_later(다 들어가는 날로) | place_today | skip
    var options: [String]
    var partialSlot: AvailabilitySlot?
    var fullSlot: AvailabilitySlot?
}

struct TodayAvailability: Codable, Hashable, Sendable {
    var freeMinutes: Int
    var largestMinutes: Int
    var slots: [AvailabilitySlot]
}

struct AssistantAvailability: Codable, Hashable, Sendable {
    var today: TodayAvailability
    var fitChecks: [FitCheck]
}

/// 이미 있는 할 일에 사용자가 답한 예상 시간. 제안을 적용할 때 함께 저장한다.
struct EstimateUpdate: Codable, Hashable, Sendable { var todoId: String; var minutes: Int }

struct DroppedItem: Codable, Hashable, Sendable { var rule: String; var detail: String }

struct ProposalEnvelope: Codable, Sendable {
    var proposalId: UUID
    var proposal: AssistantProposal
    var dropped: [DroppedItem]
    var availability: AssistantAvailability?
    var estimateUpdates: [EstimateUpdate]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        proposalId = try c.decode(UUID.self, forKey: .proposalId)
        proposal = try c.decode(AssistantProposal.self, forKey: .proposal)
        dropped = try c.decodeIfPresent([DroppedItem].self, forKey: .dropped) ?? []
        // 덧붙는 정보는 읽지 못해도 제안 자체는 쓸 수 있어야 한다.
        availability = (try? c.decodeIfPresent(AssistantAvailability.self, forKey: .availability)) ?? nil
        estimateUpdates = (try? c.decodeIfPresent([EstimateUpdate].self, forKey: .estimateUpdates)) ?? []
    }
}

// MARK: - 스트림 처리

/// `stream(function: "assistant")`이 주는 이벤트를 쌓는다: message_delta → proposal → (error).
struct AssistantStreamState: Equatable {
    var message = ""
    var envelopeData: Data?
    var errorCode: String?
    var receivedFirstDelta = false
}

enum AssistantStream {
    private struct Delta: Decodable { var text: String }
    private struct ErrorBody: Decodable { var code: String }

    /// 받은 순서대로 한 이벤트를 반영한다. 알 수 없는 이벤트는 무시한다.
    static func reduce(_ state: inout AssistantStreamState, event: ServerEvent) {
        switch event.name {
        case "message_delta":
            if let d = try? TodayCoding.decoder.decode(Delta.self, from: event.data) {
                state.message += d.text
                state.receivedFirstDelta = true
            }
        case "proposal":
            state.envelopeData = event.data
        case "error":
            state.errorCode = (try? TodayCoding.decoder.decode(ErrorBody.self, from: event.data))?.code ?? "unknown"
        default:
            break
        }
    }

    static func envelope(from state: AssistantStreamState) -> ProposalEnvelope? {
        state.envelopeData.flatMap { try? TodayCoding.decoder.decode(ProposalEnvelope.self, from: $0) }
    }
}

// MARK: - 부분 적용 선택

/// 초안 카드에서 사용자가 고른 항목. 규칙:
/// - 예정 시간을 고르면 그 할 일(`new:N`)도 함께 고른다(할 일이 없으면 시간만 남는다).
/// - 새 할 일을 빼면 그 할 일에 걸린 예정 시간도 함께 뺀다.
struct ProposalSelection: Equatable {
    var todoIndexes: Set<Int>
    var blockIndexes: Set<Int>
    var applyDone: Bool

    init(for proposal: AssistantProposal) {
        todoIndexes = Set(proposal.todos.indices)
        blockIndexes = Set(proposal.blocks.indices)
        applyDone = !proposal.doneTodoIds.isEmpty
    }

    mutating func toggleTodo(_ i: Int, in proposal: AssistantProposal) {
        if todoIndexes.contains(i) {
            todoIndexes.remove(i)
            for (bi, b) in proposal.blocks.enumerated() where b.newTodoIndex == i { blockIndexes.remove(bi) }
        } else {
            todoIndexes.insert(i)
        }
    }

    mutating func toggleBlock(_ i: Int, in proposal: AssistantProposal) {
        if blockIndexes.contains(i) {
            blockIndexes.remove(i)
        } else {
            blockIndexes.insert(i)
            if let n = proposal.blocks[i].newTodoIndex { todoIndexes.insert(n) }
        }
    }

    func isEverythingSelected(in proposal: AssistantProposal) -> Bool {
        todoIndexes.count == proposal.todos.count && blockIndexes.count == proposal.blocks.count
            && (applyDone || proposal.doneTodoIds.isEmpty)
    }

    var isEmpty: Bool { todoIndexes.isEmpty && blockIndexes.isEmpty && !applyDone }

    /// `apply_proposal` 인자. 전부 고른 경우 서버 규칙(null = 전부)을 따른다.
    func params(proposalID: UUID, proposal: AssistantProposal) -> [String: JSONValue] {
        let all = isEverythingSelected(in: proposal)
        func arr(_ s: Set<Int>) -> JSONValue { .array(s.sorted().map { .number(Double($0)) }) }
        return [
            "p_proposal_id": .uuid(proposalID),
            "p_todo_indexes": all ? .null : arr(todoIndexes),
            "p_block_indexes": all ? .null : arr(blockIndexes),
            "p_apply_done": .bool(applyDone),
        ]
    }
}

// MARK: - 동의

protocol ConsentStoring: AnyObject {
    var hasConsented: Bool { get set }
}

final class UserDefaultsConsent: ConsentStoring {
    private let key = "pondu.assistant.consent.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var hasConsented: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}

// MARK: - 예상 시간 묻기 알림

/// 화면을 보고 있지 않을 때 "얼마나 걸릴까요?"를 알림으로 알린다. 답은 앱 안에서 고른다.
protocol EstimateAskNotifying: AnyObject, Sendable {
    func notify(title: String, body: String) async
    func cancel()
}

final class LocalEstimateAskNotifier: EstimateAskNotifying, @unchecked Sendable {
    static let identifier = "pondu.estimate-ask"
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func notify(title: String, body: String) async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.identifier, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        try? await center.add(request)
    }

    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }
}

// MARK: - 비서 모델

final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired = false
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return _fired }
    func fire() { lock.lock(); _fired = true; lock.unlock() }
}

enum AssistantKind: String, Sendable { case capture, planDay = "plan_day", reschedule }

@MainActor @Observable
final class AssistantModel {
    enum Phase: Equatable {
        case needsConsent
        case idle
        case streaming
        case proposal
        case applied
        case failed(code: String)      // 직접 입력으로 넘어간다
    }

    private(set) var phase: Phase
    private(set) var message = ""
    private(set) var envelope: ProposalEnvelope?
    var selection: ProposalSelection?
    var inputText: String
    private(set) var isApplying = false
    var applyError: String?
    let kind: AssistantKind

    // 예상 시간 묻기: 30분으로 잡아 둔 일을 2분 동안 묻는다. 답이 없거나 건너뛰면 30분 그대로 둔다.
    /// 아직 묻고 있는 일(`new:N` 또는 할 일 id).
    private(set) var pendingAsks: [String] = []
    /// 이 시각까지 답이 없으면 묻기를 끝낸다.
    private(set) var askDeadline: Date?
    /// 사용자가 "이번엔 건너뛰기"를 고른, 다 들어가지 않는 일.
    private(set) var skippedFits: Set<String> = []
    private(set) var isAdjusting = false
    /// 이미 있는 할 일에 답한 예상 시간(할 일 id → 분). 적용할 때 저장한다.
    private(set) var answeredEstimates: [String: Int] = [:]
    static let askWindow: TimeInterval = 120
    static let estimateChoices = [15, 30, 45, 60, 90, 120]

    @ObservationIgnored private let asker: EstimateAskNotifying?
    @ObservationIgnored private var askTimer: Task<Void, Never>?
    @ObservationIgnored private let today: TodayModel
    @ObservationIgnored private let consent: ConsentStoring
    @ObservationIgnored private let sessionSignal: SessionEndSignal?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var readerTask: Task<AssistantStreamState, Never>?
    static let timeout: UInt64 = 20_000_000_000      // 비서 20초

    init(kind: AssistantKind, text: String = "", today: TodayModel, consent: ConsentStoring, signal: SessionEndSignal? = nil,
         asker: EstimateAskNotifying? = nil) {
        self.kind = kind; self.inputText = text; self.today = today; self.consent = consent; self.sessionSignal = signal
        self.asker = asker
        self.phase = consent.hasConsented ? .idle : .needsConsent
    }

    func acceptConsent() { consent.hasConsented = true; phase = .idle }

    /// 하루 정리·남은 일 조정은 입력 없이 바로, 한 줄 입력은 문장이 있어야 시작한다.
    var canSend: Bool {
        guard phase == .idle || isFailed else { return false }
        return kind != .capture || !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    /// 시험용: 진행 중인 요청이 끝날 때까지 기다린다.
    func waitUntilDone() async { await task?.value }

    func cancel() { task?.cancel(); readerTask?.cancel(); task = nil; endAsking() }

    func send() {
        guard canSend else { return }
        phase = .streaming
        message = ""; envelope = nil; selection = nil; applyError = nil
        endAsking(); skippedFits = []; answeredEstimates = [:]
        task = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        // 계획 직전에 캘린더를 다시 읽는다. 일정 제목은 보내지 않고 구간만 보낸다.
        let busy = await today.busyForAssistant(days: kind == .reschedule ? 2 : 1)
        let body = Self.requestBody(kind: kind, text: inputText, now: today.now, timeZone: today.timeZone,
                                    busy: busy, session: sessionSignal)
        let stream = today.backend.stream(function: "assistant", body: body)
        let flag = TimeoutFlag()
        let reader = Task { [weak self] () -> AssistantStreamState in
            var local = AssistantStreamState()
            do {
                for try await ev in stream {
                    AssistantStream.reduce(&local, event: ev)
                    let snapshot = local
                    self?.publish(snapshot)
                }
            } catch {
                if !(error is CancellationError) { local.errorCode = (error as? BackendError)?.code ?? "unknown" }
            }
            return local
        }
        readerTask = reader
        // 비서 요청 시간 제한 20초: 넘으면 읽기를 끊고 직접 입력으로 넘긴다.
        let timer = Task {
            try? await Task.sleep(nanoseconds: Self.timeout)
            if !Task.isCancelled { flag.fire(); reader.cancel() }
        }
        let state = await reader.value
        timer.cancel()
        readerTask = nil
        finish(state, timedOut: flag.fired)
    }

    private func publish(_ state: AssistantStreamState) { message = state.message }

    private func finish(_ state: AssistantStreamState, timedOut: Bool) {
        if task?.isCancelled == true && state.envelopeData == nil && !timedOut { phase = .idle; return }
        if let code = state.errorCode { phase = .failed(code: code); return }
        if let env = AssistantStream.envelope(from: state) {
            envelope = env
            selection = ProposalSelection(for: env.proposal)
            if message.isEmpty { message = env.proposal.message }
            phase = .proposal
            beginAsking(env.proposal.estimateAsks)
            return
        }
        phase = .failed(code: timedOut ? "timeout" : "assistant_unavailable")
    }

    nonisolated static func requestBody(kind: AssistantKind, text: String, now: Date, timeZone: TimeZone,
                                        busy: [BusyInterval], session: SessionEndSignal?) -> JSONValue {
        .object([
            "kind": .string(kind.rawValue),
            "text": .string(text),
            "pasted": .null,
            "now": .date(now),
            "tz": .string(timeZone.identifier),
            "busy": BusyTime.payload(busy),
            "session": session?.jsonValue ?? .null,
        ])
    }

    // MARK: 예상 시간 묻기와 가용 시간

    private func beginAsking(_ refs: [String]) {
        guard !refs.isEmpty else { return }
        pendingAsks = refs
        let deadline = today.now.addingTimeInterval(Self.askWindow)
        askDeadline = deadline
        askTimer?.cancel()
        askTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.askWindow * 1_000_000_000))
            if !Task.isCancelled { self?.expireAsks() }
        }
    }

    private func endAsking() {
        askTimer?.cancel(); askTimer = nil
        pendingAsks = []; askDeadline = nil
        asker?.cancel()
    }

    /// 2분이 지났다: 남은 질문은 30분으로 둔 채 끝낸다.
    func expireAsks() { endAsking() }

    /// 건너뛰기: 이 일은 30분으로 둔다.
    func skipEstimate(_ ref: String) {
        pendingAsks.removeAll { $0 == ref }
        if pendingAsks.isEmpty { endAsking() }
    }

    /// 화면을 떠날 때 부른다. 아직 묻는 중이면 알림으로 알린다.
    func notifyPendingAsks() {
        guard let ref = pendingAsks.first, let p = envelope?.proposal else { return }
        let title = self.title(forRef: ref, in: p)
        let more = pendingAsks.count > 1 ? " 외 \(pendingAsks.count - 1)개" : ""
        let asker = self.asker
        Task { await asker?.notify(title: "얼마나 걸릴까요?", body: "‘\(title)’\(more)의 예상 시간을 알려 주세요. 2분 안에 답이 없으면 30분으로 잡아요.") }
    }

    func title(forRef ref: String, in proposal: AssistantProposal) -> String {
        if ref.hasPrefix("new:"), let n = Int(ref.dropFirst(4)), proposal.todos.indices.contains(n) { return proposal.todos[n].title }
        return today.snapshot?.todo(UUID(uuidString: ref))?.title ?? "할 일"
    }

    /// 답한 예상 시간으로 제안을 고친다. 30분이면 이미 그렇게 잡혀 있으니 서버에 묻지 않는다(예상 시간만 기억한다).
    func answerEstimate(_ ref: String, minutes: Int) async {
        guard pendingAsks.contains(ref) else { return }
        await adjust(estimates: [(ref, minutes)], fits: [])
    }

    /// 다 들어가지 않는 일의 선택: partial_today | move_later | place_today 는 서버가 자리를 잡고, skip 은 여기서 끝낸다.
    func chooseFit(_ ref: String, option: String) async {
        if option == "skip" { skippedFits.insert(ref); return }
        await adjust(estimates: [], fits: [(ref, option)])
    }

    /// 화면에 보여 줄 점검: 건너뛴 것은 뺀다.
    var fitChecks: [FitCheck] { (envelope?.availability?.fitChecks ?? []).filter { !skippedFits.contains($0.todoRef) } }

    nonisolated static func adjustBody(proposalID: UUID, estimates: [(String, Int)], fits: [(String, String)],
                                       timeZone: TimeZone, busy: [BusyInterval]) -> JSONValue {
        .object([
            "kind": .string("adjust"),
            "proposal_id": .uuid(proposalID),
            "estimates": .array(estimates.map { .object(["todo_ref": .string($0.0), "minutes": .int($0.1)]) }),
            "fits": .array(fits.map { .object(["todo_ref": .string($0.0), "option": .string($0.1)]) }),
            "tz": .string(timeZone.identifier),
            "busy": BusyTime.payload(busy),
        ])
    }

    /// 모델을 부르지 않는 요청이다. 서버가 고친 제안을 새 제안으로 돌려주고, 그것으로 화면을 바꾼다.
    private func adjust(estimates: [(String, Int)], fits: [(String, String)]) async {
        guard let env = envelope, phase == .proposal, !isAdjusting, !isApplying else { return }
        isAdjusting = true
        applyError = nil
        defer { isAdjusting = false }
        let busy = await today.busyForAssistant(days: 7)
        let body = Self.adjustBody(proposalID: env.proposalId, estimates: estimates, fits: fits, timeZone: today.timeZone, busy: busy)
        var state = AssistantStreamState()
        do {
            for try await ev in today.backend.stream(function: "assistant", body: body) { AssistantStream.reduce(&state, event: ev) }
        } catch {
            state.errorCode = (error as? BackendError)?.code ?? "unknown"
        }
        guard state.errorCode == nil, let next = AssistantStream.envelope(from: state) else {
            applyError = state.errorCode == "proposal_not_found" ? "이 제안은 더 이상 쓸 수 없어요. 다시 요청해 주세요." : "바꾸지 못했어요. 잠시 뒤에 다시 해 주세요."
            return
        }
        for u in next.estimateUpdates { answeredEstimates[u.todoId] = u.minutes }
        envelope = next
        // 처음 초안의 안내는 조정 전 시간표를 설명할 수 있다.
        message = ""
        selection = ProposalSelection(for: next.proposal)
        // 답한 일은 서버가 estimate_asks 에서 뺀다. 남은 질문만 이어서 묻는다(시간은 다시 재지 않는다).
        pendingAsks = pendingAsks.filter { next.proposal.estimateAsks.contains($0) }
        if pendingAsks.isEmpty { endAsking() }
    }

    /// 선택한 것만 저장한다. 이 호출 전에는 서버에 아무것도 남지 않는다.
    func apply() async {
        guard let env = envelope, let sel = selection, !sel.isEmpty, !isApplying else { return }
        isApplying = true
        applyError = nil
        defer { isApplying = false }
        do {
            let _: JSONValue = try await today.backend.rpc("apply_proposal", sel.params(proposalID: env.proposalId, proposal: env.proposal))
            // 이미 있는 할 일에 답한 예상 시간을 저장한다. 실패해도 적용은 끝난 것이다(예상 시간은 나중에 고칠 수 있다).
            for (id, minutes) in answeredEstimates {
                let _: JSONValue? = try? await today.backend.rpc("update_todo", [
                    "p_todo_id": .string(id), "p_patch": .object(["estimate_min": .int(minutes)]),
                ])
            }
            endAsking()
            phase = .applied
            await today.load()                  // 새 할 일과 예정 시간을 받고 알림을 다시 잡는다
        } catch {
            switch (error as? BackendError)?.code {
            case "proposal_already_applied": phase = .applied; await today.load()
            case "proposal_not_found": applyError = "이 제안은 더 이상 쓸 수 없어요. 다시 요청해 주세요."
            default: applyError = TodayModel.message(for: error, action: "적용하지")
            }
        }
    }

    /// 보정된 예상 시간 안내(예: "과제는 평소 1.4배 걸려서 85분으로 잡았어요").
    func estimateNotes() -> [String] {
        guard let p = envelope?.proposal, let factors = today.snapshot?.estimateFactors else { return [] }
        return p.todos.compactMap { TodayLogic.estimateNote(categoryRaw: $0.category, estimateMin: $0.estimateMin, factors: factors) }
    }

    /// 실패했을 때 직접 입력으로 넘기는 값: 문장을 그대로 할 일 제목으로 쓴다.
    func manualDraft() -> TodayModel.TodoDraft {
        TodayModel.TodoDraft(title: inputText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func failureText(code: String) -> String {
        switch code {
        case "quota_exceeded": return "오늘 쓸 수 있는 비서 횟수를 다 썼어요. 직접 입력해 주세요."
        case "rate_limited": return "요청이 너무 잦아요. 잠시 뒤에 다시 해 보거나 직접 입력해 주세요."
        case "timeout": return "비서 응답이 늦어요. 직접 입력해 주세요."
        default: return "비서를 쓸 수 없어요. 직접 입력해 주세요."
        }
    }
}
