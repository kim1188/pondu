import Foundation
import Observation
import PonduCore

/// 오늘 화면의 상태와 동작. Backend 프로토콜에만 의존한다.
@MainActor @Observable
final class TodayModel {
    // 화면 상태
    private(set) var snapshot: TodaySnapshot?
    private(set) var events: [CalendarEventLite] = []
    private(set) var busy: [BusyInterval] = []
    private(set) var calendarAccess: CalendarAccess = .notDetermined
    private(set) var isLoading = false          // 첫 화면 뼈대용(저장분도 없을 때)
    private(set) var isRefreshing = false
    private(set) var loadFailed = false
    var errorMessage: String?
    /// 세션이 `더 해야 해요`로 끝난 뒤 남은 일 조정을 제안하는 신호.
    private(set) var rescheduleHint: SessionEndSignal?

    @ObservationIgnored let backend: Backend
    @ObservationIgnored let sessions: SessionControlling
    @ObservationIgnored let nowProvider: @Sendable () -> Date
    @ObservationIgnored let timeZone: TimeZone
    @ObservationIgnored private let store: TodaySnapshotStoring
    @ObservationIgnored let calendar: CalendarBusyProviding
    @ObservationIgnored private let notifier: NotificationScheduling
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(backend: Backend, sessions: SessionControlling, now: @escaping @Sendable () -> Date,
         timeZone: TimeZone = .current, store: TodaySnapshotStoring, calendar: CalendarBusyProviding,
         notifier: NotificationScheduling) {
        self.backend = backend; self.sessions = sessions; self.nowProvider = now; self.timeZone = timeZone
        self.store = store; self.calendar = calendar; self.notifier = notifier
    }

    var now: Date { nowProvider() }
    var dayKey: String { TodayLogic.dayKey(now, timeZone: timeZone) }
    var cal: Calendar { TodayLogic.calendar(timeZone: timeZone) }

    // MARK: 파생 값
    var startable: [TodayBlock] { snapshot.map { TodayLogic.startable(blocks: $0.blocks, todos: $0.todos, now: now) } ?? [] }
    var upcoming: [TodayBlock] { snapshot.map { TodayLogic.upcoming(blocks: $0.blocks, now: now) } ?? [] }
    var remaining: [TodayTodo] { snapshot.map { TodayLogic.remaining(todos: $0.todos) } ?? [] }
    var doneToday: [TodayTodo] { snapshot.map { TodayLogic.doneToday(todos: $0.todos) } ?? [] }
    var threads: [TodayThread] { snapshot?.threads.filter { $0.archivedAt == nil } ?? [] }
    var live: TodayLiveSession? { snapshot?.liveSession }

    // MARK: 불러오기

    /// 저장분으로 먼저 그리고, `get_today`와 캘린더를 동시에 받아 갱신한다.
    func load() async {
        if snapshot == nil || snapshot?.day != dayKey {
            snapshot = store.load(day: dayKey)
        }
        isLoading = snapshot == nil
        isRefreshing = true
        loadFailed = false
        async let remote: Result<TodayWire, Error> = fetchToday()
        async let cal: Void = refreshCalendar()
        let (result, _) = await (remote, cal)
        isRefreshing = false
        isLoading = false
        switch result {
        case .success(let wire):
            let snap = TodaySnapshot(day: dayKey, wire: wire, fetchedAt: now)
            snapshot = snap
            store.save(snap)
            await syncNotifications()
        case .failure:
            // 저장분이 있으면 그대로 보여 주고, 없을 때만 오류 화면.
            loadFailed = snapshot == nil
            if snapshot != nil { errorMessage = "최신 정보를 받지 못했어요. 저장된 내용을 보여 드려요." }
        }
    }

    private func fetchToday() async -> Result<TodayWire, Error> {
        do {
            let wire: TodayWire = try await backend.rpc("get_today", [
                "p_day": .string(dayKey), "p_tz": .string(timeZone.identifier),
            ])
            return .success(wire)
        } catch { return .failure(error) }
    }

    /// 앱 실행·복귀·계획 직전에 부른다.
    func refreshCalendar() async {
        calendarAccess = calendar.access
        guard calendarAccess == .granted else { events = []; busy = []; return }
        let window = BusyTime.dayWindow(containing: now, calendar: cal)
        let evs = calendar.events(in: window)
        events = evs
        busy = BusyTime.intervals(from: evs, within: window)
    }

    func requestCalendarAccess() async {
        calendarAccess = await calendar.requestAccess()
        if calendarAccess == .granted, calendar.selectedCalendarIDs == nil {
            // 처음에는 아무것도 고르지 않은 상태로 두고 선택 화면을 연다(화면에서 처리).
        }
        await refreshCalendar()
    }

    func setSelectedCalendars(_ ids: Set<String>) async {
        calendar.selectedCalendarIDs = ids
        await refreshCalendar()
    }

    /// 비서 요청 직전에 최신 바쁜 시간 구간을 돌려준다(제목 없음). `days`는 오늘 포함 일수.
    func busyForAssistant(days: Int = 1) async -> [BusyInterval] {
        await refreshCalendar()
        guard calendarAccess == .granted else { return [] }
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: max(1, days), to: start) ?? start.addingTimeInterval(86_400)
        let window = DateInterval(start: start, end: end)
        return BusyTime.intervals(from: calendar.events(in: window), within: window)
    }

    // MARK: 알림

    func syncNotifications() async {
        guard let snap = snapshot else { return }
        let plans = NotificationPlanner.plan(blocks: snap.blocks, todos: snap.todos, now: now)
        if !plans.isEmpty { _ = await notifier.requestAuthorizationIfNeeded() }
        await notifier.sync(plans, covering: BusyTime.dayWindow(containing: now, calendar: cal))
    }

    // MARK: 시작

    /// `지금 시작`. 서버 응답을 기다리지 않고 시작 화면을 바로 띄운다.
    func start(block: TodayBlock) {
        let todo = snapshot?.todo(block.todoId)
        let threadID = block.threadId ?? todo?.threadId
        presentStart(todo: todo, threadID: threadID, blockID: block.id, fallbackTitle: nil)
    }

    func start(todo: TodayTodo) {
        let block = snapshot?.blocks.first { $0.todoId == todo.id && $0.isPlanned && $0.endAt > now }
        presentStart(todo: todo, threadID: todo.threadId, blockID: block?.id, fallbackTitle: nil)
    }

    func startFromNotification(blockID: UUID?, todoID: UUID?) {
        if let blockID, let b = snapshot?.blocks.first(where: { $0.id == blockID }) { start(block: b); return }
        if let todoID, let t = snapshot?.todo(todoID) { start(todo: t); return }
        sessions.presentStart(StartSessionRequest(category: nil, threadID: nil, todoID: todoID, planBlockID: blockID,
                                                  title: nil, joinedSessionID: nil, joinedWithName: nil))
    }

    private func presentStart(todo: TodayTodo?, threadID: UUID?, blockID: UUID?, fallbackTitle: String?) {
        let thread = snapshot?.thread(threadID)
        let category = thread?.primaryCategory.flatMap { Category(rawValue: $0) }
        sessions.presentStart(StartSessionRequest(category: category, threadID: threadID, todoID: todo?.id,
                                                  planBlockID: blockID, title: todo?.title ?? thread?.title ?? fallbackTitle,
                                                  joinedSessionID: nil, joinedWithName: nil))
    }

    // MARK: 할 일

    /// 체크를 누르는 즉시 바꾸고 서버에 보낸다. 실패하면 되돌린다.
    func toggleDone(_ todo: TodayTodo) {
        let newStatus = todo.isDone ? "open" : "done"
        optimistic({ snap in
            guard let i = snap.todos.firstIndex(where: { $0.id == todo.id }) else { return }
            snap.todos[i].status = newStatus
            snap.todos[i].completedAt = newStatus == "done" ? self.now : nil
            snap.todos[i].completionSource = newStatus == "done" ? "user_action" : nil
        }, send: { [backend] in
            try await backend.rpcVoidResult("set_todo_status", ["p_todo_id": .uuid(todo.id), "p_status": .string(newStatus)])
        }, afterSuccess: { [weak self] in await self?.syncNotifications() })
    }

    func deleteTodo(_ todo: TodayTodo) {
        optimistic({ snap in
            snap.todos.removeAll { $0.id == todo.id }
            snap.blocks.removeAll { $0.todoId == todo.id }
        }, send: { [backend] in
            try await backend.rpcVoid("delete_todo", ["p_todo_id": .uuid(todo.id)])
        }, afterSuccess: { [weak self] in await self?.syncNotifications() })
    }

    struct TodoDraft: Equatable {
        var title = ""
        var threadID: UUID?
        var due: Date?
        var dueHasTime = false
        var estimateMin: Int?
        var isValid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 임시 항목을 먼저 넣고 서버가 돌려준 값으로 바꾼다.
    @discardableResult
    func addTodo(_ draft: TodoDraft) async -> Bool {
        guard draft.isValid else { return false }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let temp = TodayTodo(threadId: draft.threadID, title: title, dueAt: draft.due, dueHasTime: draft.dueHasTime, estimateMin: draft.estimateMin)
        ensureSnapshot()
        snapshot?.todos.append(temp)
        do {
            let created: TodayTodo = try await backend.rpc("create_todo", [
                "p_title": .string(title), "p_thread_id": .uuid(draft.threadID), "p_due_at": .date(draft.due),
                "p_due_has_time": .bool(draft.dueHasTime), "p_estimate_min": .int(draft.estimateMin),
            ])
            if let i = snapshot?.todos.firstIndex(where: { $0.id == temp.id }) { snapshot?.todos[i] = created }
            persist()
            return true
        } catch {
            snapshot?.todos.removeAll { $0.id == temp.id }
            errorMessage = Self.message(for: error, action: "할 일을 추가하지")
            return false
        }
    }

    func updateTodo(_ todo: TodayTodo, draft: TodoDraft) async -> Bool {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        let before = snapshot
        if let i = snapshot?.todos.firstIndex(where: { $0.id == todo.id }) {
            snapshot?.todos[i].title = title
            snapshot?.todos[i].threadId = draft.threadID
            snapshot?.todos[i].dueAt = draft.due
            snapshot?.todos[i].dueHasTime = draft.dueHasTime
            snapshot?.todos[i].estimateMin = draft.estimateMin
        }
        do {
            let updated: TodayTodo = try await backend.rpc("update_todo", [
                "p_todo_id": .uuid(todo.id),
                "p_patch": .object(["title": .string(title), "thread_id": .uuid(draft.threadID), "due_at": .date(draft.due),
                                    "due_has_time": .bool(draft.dueHasTime), "estimate_min": .int(draft.estimateMin)]),
            ])
            if let i = snapshot?.todos.firstIndex(where: { $0.id == todo.id }) { snapshot?.todos[i] = updated }
            persist()
            return true
        } catch {
            snapshot = before
            errorMessage = Self.message(for: error, action: "할 일을 고치지")
            return false
        }
    }

    // MARK: 이어가는 일

    func createThread(title: String, category: Category?, shareTitle: String?) async -> TodayThread? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        do {
            let thread: TodayThread = try await backend.rpc("create_thread", [
                "p_title": .string(t),
                "p_primary_category": category.map { .string($0.rawValue) } ?? .null,
                "p_share_title": .text(shareTitle?.isEmpty == false ? shareTitle : nil),
                "p_default_visibility": .string("private"),
            ])
            ensureSnapshot()
            snapshot?.threads.append(thread)
            persist()
            return thread
        } catch {
            errorMessage = Self.message(for: error, action: "이어가는 일을 만들지")
            return nil
        }
    }

    // MARK: 예정 시간

    func createBlock(todo: TodayTodo, start: Date, end: Date, locked: Bool) async -> Bool {
        guard end > start else { errorMessage = "끝나는 시각이 시작보다 늦어야 해요."; return false }
        let temp = TodayBlock(todoId: todo.id, threadId: todo.threadId, startAt: start, endAt: end, locked: locked)
        ensureSnapshot()
        snapshot?.blocks.append(temp)
        do {
            let created: TodayBlock = try await backend.rpc("create_plan_block", [
                "p_todo_id": .uuid(todo.id), "p_thread_id": .uuid(todo.threadId),
                "p_start_at": .date(start), "p_end_at": .date(end), "p_locked": .bool(locked),
            ])
            if let i = snapshot?.blocks.firstIndex(where: { $0.id == temp.id }) { snapshot?.blocks[i] = created }
            persist()
            await syncNotifications()
            return true
        } catch {
            snapshot?.blocks.removeAll { $0.id == temp.id }
            errorMessage = Self.message(for: error, action: "예정 시간을 만들지")
            return false
        }
    }

    func moveBlock(_ block: TodayBlock, start: Date, end: Date) async -> Bool {
        guard end > start else { errorMessage = "끝나는 시각이 시작보다 늦어야 해요."; return false }
        let before = snapshot
        if let i = snapshot?.blocks.firstIndex(where: { $0.id == block.id }) {
            snapshot?.blocks[i].startAt = start; snapshot?.blocks[i].endAt = end
        }
        do {
            let updated: TodayBlock = try await backend.rpc("update_plan_block", [
                "p_block_id": .uuid(block.id), "p_patch": .object(["start_at": .date(start), "end_at": .date(end)]),
            ])
            if let i = snapshot?.blocks.firstIndex(where: { $0.id == block.id }) { snapshot?.blocks[i] = updated }
            persist()
            await syncNotifications()      // 예정 시간이 바뀌면 알림을 다시 잡는다
            return true
        } catch {
            snapshot = before
            errorMessage = Self.message(for: error, action: "예정 시간을 옮기지")
            return false
        }
    }

    func setLocked(_ block: TodayBlock, locked: Bool) {
        optimistic({ snap in
            if let i = snap.blocks.firstIndex(where: { $0.id == block.id }) { snap.blocks[i].locked = locked }
        }, send: { [backend] in
            try await backend.rpcVoidResult("update_plan_block", ["p_block_id": .uuid(block.id), "p_patch": .object(["locked": .bool(locked)])])
        }, afterSuccess: nil)
    }

    func deleteBlock(_ block: TodayBlock) {
        optimistic({ snap in snap.blocks.removeAll { $0.id == block.id } }, send: { [backend] in
            try await backend.rpcVoid("delete_plan_block", ["p_block_id": .uuid(block.id)])
        }, afterSuccess: { [weak self] in await self?.syncNotifications() })
    }

    /// 겹치는 바쁜 시간이 있는지(예정 시간을 잡을 때 경고용).
    func conflicts(start: Date, end: Date) -> [BusyInterval] {
        guard end > start else { return [] }
        return BusyTime.conflicts(DateInterval(start: start, end: end), with: busy)
    }

    // MARK: 세션 종료 신호 (G가 보낸다 — 보고의 계약 변경 제안 참고)

    func receiveSessionEnd(_ signal: SessionEndSignal) {
        rescheduleHint = signal.outcome == "more" ? signal : nil
    }

    func dismissRescheduleHint() { rescheduleHint = nil }

    // MARK: 내부

    private func ensureSnapshot() {
        if snapshot == nil {
            snapshot = TodaySnapshot(day: dayKey, wire: TodayWire(todos: [], blocks: [], threads: [], liveSession: nil, estimateFactors: [:]), fetchedAt: now)
        }
    }

    private func persist() { if let s = snapshot { store.save(s) } }

    /// 화면을 먼저 바꾸고 뒤에서 보낸다. 실패하면 이전 값으로 되돌리고 알린다.
    private func optimistic(_ change: (inout TodaySnapshot) -> Void,
                            send: @escaping () async throws -> Void,
                            afterSuccess: (() async -> Void)?) {
        guard var snap = snapshot else { return }
        let before = snap
        change(&snap)
        snapshot = snap
        persist()
        Task { [weak self] in
            do {
                try await send()
                await afterSuccess?()
            } catch {
                guard let self else { return }
                self.snapshot = before
                self.persist()
                self.errorMessage = Self.message(for: error, action: "저장하지")
            }
        }
    }

    static func message(for error: Error, action: String) -> String {
        let code = (error as? BackendError)?.code
        switch code {
        case "network", "timeout": return "연결이 불안정해서 \(action) 못했어요. 잠시 뒤 다시 해 주세요."
        case "not_found": return "이미 지워졌거나 바뀐 항목이에요. 새로 불러올게요."
        default: return "\(action) 못했어요."
        }
    }
}

/// 세션이 끝났다는 신호(G → I). 계약에는 없어서 NotificationCenter로 받는다.
struct SessionEndSignal: Equatable, Sendable {
    var todoID: UUID?
    var outcome: String         // done, more, stop
    var note: String?

    static let notificationName = Notification.Name("pondu.session.ended")

    init(todoID: UUID?, outcome: String, note: String?) { self.todoID = todoID; self.outcome = outcome; self.note = note }

    /// userInfo: ["todo_id": String?, "outcome": String, "note": String?]
    init?(userInfo: [AnyHashable: Any]?) {
        guard let outcome = userInfo?["outcome"] as? String else { return nil }
        self.outcome = outcome
        self.todoID = (userInfo?["todo_id"] as? String).flatMap(UUID.init(uuidString:))
        self.note = userInfo?["note"] as? String
    }

    var jsonValue: JSONValue {
        .object(["todo_id": .uuid(todoID), "outcome": .string(outcome), "note": .text(note)])
    }
}

extension Backend {
    /// 반환값이 있는 함수를 결과 없이 호출한다(서버는 Todo/PlanBlock을 돌려주지만 여기서는 쓰지 않는다).
    func rpcVoidResult(_ name: String, _ params: [String: JSONValue]) async throws {
        let _: JSONValue = try await rpc(name, params)
    }
}
