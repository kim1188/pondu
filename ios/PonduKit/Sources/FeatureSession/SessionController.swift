import Foundation
import Observation
import PonduCore
#if canImport(Network)
import Network
#endif

/// 세션 시작·일시 정지·종료를 맡는 컨트롤러. Backend 프로토콜에만 의존한다.
///
/// - 누르는 즉시 화면에 반영하고 서버 전송은 뒤에서 한다. 실패하면 이전 상태로 되돌리고 알린다.
/// - 시작은 `p_client_id`로 보내 재시도해도 한 번만 만들어진다. 연결이 없으면 기기에 적어 두었다가
///   연결되면 `p_offline_started_at`과 함께 보낸다.
/// - 경과 시간은 서버가 준 값에서 단조 시계로 이어 센다(기기 시각 변경에 영향 없음).
@MainActor
@Observable
public final class SessionController: SessionControlling {

    enum Route: Equatable { case none, start, end, confirmEnd }

    /// 진행 중 세션을 화면에 그리기 위한 값.
    struct LiveState: Equatable {
        var clientID: UUID
        var serverID: UUID?
        var category: String
        var shareTitle: String?
        var joinedWithName: String?
        var phase: SessionPhase
        var clock: SessionClock
        var startedAt: Date?
        var isOfflineStart: Bool
        var captureMode: String
        var todoID: UUID?

        var awaitingServer: Bool { serverID == nil }
    }

    // MARK: SessionControlling
    /// 서버가 확인한 진행 중 세션. 서버 응답 전(방금 눌러 임시로 그리는 동안)에는 nil.
    public private(set) var liveSession: SessionDTO?
    /// 가장 최근에 끝낸 세션(오늘 탭이 갱신 신호로 쓸 수 있다).
    public private(set) var lastEndedSession: SessionDTO?

    // MARK: 화면 상태
    private(set) var live: LiveState?
    var route: Route = .none
    private(set) var draft: StartDraft?
    var endDraft = EndDraft()
    var confirmDate = Date()
    var alert: AlertInfo?
    private(set) var toast: String?
    private(set) var isBusy = false

    // MARK: 의존성
    private let backend: Backend
    private let store: PendingStoring
    private let photoProcessor: PhotoProcessing
    private let photosDirectory: URL
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private let sleeper: @Sendable (TimeInterval) async -> Void

    @ObservationIgnored private var pending: PendingState
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var mutationTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var photoUploadTask: Task<Void, Never>?
    #if canImport(Network)
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    #endif

    init(backend: Backend,
         store: PendingStoring,
         photoProcessor: PhotoProcessing,
         photosDirectory: URL,
         now: @escaping @Sendable () -> Date = { Date() },
         uptime: @escaping @Sendable () -> TimeInterval = { SessionClock.monotonicNow() },
         sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         }) {
        self.backend = backend
        self.store = store
        self.photoProcessor = photoProcessor
        self.photosDirectory = photosDirectory
        self.now = now
        self.uptime = uptime
        self.sleeper = sleeper
        self.pending = store.load()
        restoreProvisionalFromPending()
    }

    public convenience init(backend: Backend) {
        let dir = FilePendingStore.supportDirectory().appendingPathComponent("photos", isDirectory: true)
        self.init(backend: backend, store: FilePendingStore.standard(), photoProcessor: HEICPhotoProcessor(), photosDirectory: dir)
        startPathMonitor()
    }

    // MARK: - 시작 화면

    public func presentStart(_ request: StartSessionRequest) {
        guard live == nil else {
            alert = AlertInfo(title: "이미 진행 중이에요", message: "진행 중인 세션을 먼저 끝내 주세요.")
            return
        }
        discardDraftPhoto()
        let d = StartDraft(request: request)
        draft = d
        route = .start
        Task { [backend] in await d.loadThreads(using: backend) }
    }

    func cancelStart() {
        discardDraftPhoto()
        draft = nil
        route = .none
    }

    func photoDirectory(for clientID: UUID) -> URL {
        photosDirectory.appendingPathComponent(clientID.uuidString.lowercased(), isDirectory: true)
    }

    func capturePhoto(_ data: Data) {
        guard let d = draft else { return }
        d.capture(data: data, directory: photoDirectory(for: d.clientID), processor: photoProcessor)
    }

    private func discardDraftPhoto() {
        guard let d = draft else { return }
        d.removePhoto()
        try? FileManager.default.removeItem(at: photoDirectory(for: d.clientID))
    }

    /// 시작을 누른다. 서버 응답을 기다리지 않고 바로 진행 중 화면으로 바꾼다.
    func commitStart() {
        guard let d = draft, let category = d.category, !d.isProcessingPhoto, live == nil else { return }
        let title = d.shareTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPhoto = d.photo != nil
        let p = PendingStart(
            clientID: d.clientID,
            category: category,
            captureMode: hasPhoto ? "in_app_photo" : "no_photo",
            visibility: d.visibility.rawValue,
            threadID: d.threadID,
            todoID: d.todoID,
            planBlockID: d.planBlockID,
            joinedSessionID: d.joinedSessionID,
            joinedWithName: d.joinedWithName,
            shareTitle: title.isEmpty ? nil : title,
            tags: [],
            tappedAt: now(),
            hasPhoto: hasPhoto)
        if !hasPhoto { try? FileManager.default.removeItem(at: photoDirectory(for: d.clientID)) }
        live = provisionalState(for: p, offline: false)
        draft = nil
        route = .none
        startTask = Task { await self.performStart(p) }
    }

    private func provisionalState(for p: PendingStart, offline: Bool) -> LiveState {
        LiveState(clientID: p.clientID, serverID: nil, category: p.category, shareTitle: p.shareTitle,
                  joinedWithName: p.joinedWithName, phase: .live, clock: .provisional(uptime: uptime()),
                  startedAt: nil, isOfflineStart: offline, captureMode: p.captureMode, todoID: p.todoID)
    }

    private func performStart(_ p: PendingStart) async {
        do {
            let pair: SessionPair = try await backend.rpc("start_session", p.params(offlineStartedAt: nil))
            adopt(pair, clientID: p.clientID)
            queuePhotoIfNeeded(p, sessionID: pair.snapshot.id)
        } catch {
            switch classify(error) {
            case .cancelled:
                break
            case .transient:
                // 연결이 없다: 기기에 적어 두고 연결되면 보낸다.
                pending.starts.removeAll { $0.clientID == p.clientID }
                pending.starts.append(p)
                persist()
                if live?.clientID == p.clientID { live?.isOfflineStart = true }
                scheduleFlush()
            case .permanent(let code):
                await handleStartRejected(p, code: code)
            }
        }
    }

    private func handleStartRejected(_ p: PendingStart, code: String) async {
        removePhotoFiles(clientID: p.clientID)
        if code == "session_already_active" {
            // 다른 기기에서 이미 진행 중: 그 세션을 가져온다.
            if live?.clientID == p.clientID { live = nil }
            await refresh(force: true)
            alert = AlertInfo(title: "이미 진행 중이에요", message: ErrorText.message(for: code))
            return
        }
        if live?.clientID == p.clientID { live = nil }
        alert = AlertInfo(title: "시작하지 못했어요", message: ErrorText.message(for: code))
    }

    // MARK: - 일시 정지 · 재개

    func togglePause() {
        guard let before = live, !isBusy, before.phase == .live || before.phase == .paused else { return }
        var next = before
        let function: String
        if before.phase == .live {
            next.phase = .paused
            next.clock = before.clock.paused(at: uptime())
            function = "pause_session"
        } else {
            next.phase = .live
            next.clock = before.clock.resumed(at: uptime())
            function = "resume_session"
        }
        live = next
        isBusy = true
        mutationTask = Task {
            defer { self.isBusy = false }
            do {
                let id = try await self.resolveServerID()
                let pair: SessionPair = try await self.backend.rpc(function, ["p_session_id": .string(id.uuidString.lowercased())])
                self.adopt(pair, clientID: before.clientID)
            } catch {
                if self.live?.clientID == before.clientID { self.live = before }
                self.report(error, title: before.phase == .live ? "일시 정지하지 못했어요" : "다시 시작하지 못했어요")
            }
        }
    }

    // MARK: - 종료

    private var currentTodoID: UUID? { live?.todoID }

    func presentEnd() {
        guard let l = live, l.phase == .live || l.phase == .paused else { return }
        endDraft = EndDraft()
        route = .end
    }

    func dismissEnd() { if route == .end { route = .none } }

    /// 종료를 누른다. 바로 진행 중 막대를 내리고 서버 전송은 뒤에서, 실패하면 되돌린다.
    func commitEnd() {
        guard let before = live, let choice = endDraft.choice, !isBusy else { return }
        let note = endDraft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let todoID = currentTodoID
        live = nil
        route = .none
        isBusy = true
        showToast("종료했어요")
        mutationTask = Task {
            defer { self.isBusy = false }
            do {
                let id = try await self.resolveServerID()
                let pair: SessionPair = try await self.backend.rpc("end_session", [
                    "p_session_id": .string(id.uuidString.lowercased()),
                    "p_outcome": .string(choice.serverValue),
                    "p_progress_note": note.isEmpty ? .null : .string(note),
                ])
                if pair.snapshot.phase == .needsConfirmation {
                    // 한도를 넘긴 채 종료: 종료 확인 화면으로 보낸다.
                    self.toast = nil
                    self.adopt(pair, clientID: before.clientID)
                    return
                }
                self.liveSession = nil
                self.lastEndedSession = pair.dto
                self.removePhotoFilesIfNoPending(clientID: before.clientID)
                NotificationCenter.default.post(
                    name: Notification.Name("pondu.session.ended"), object: nil,
                    userInfo: ["todo_id": todoID?.uuidString.lowercased() as Any,
                               "outcome": choice.serverValue,
                               "note": (note.isEmpty ? nil : note) as Any])
            } catch {
                if self.live == nil { self.live = before }
                self.toast = nil
                self.report(error, title: "종료를 저장하지 못했어요")
            }
        }
    }

    // MARK: - 종료 확인 필요(confirm_end)

    /// 확인 화면에서 고를 수 있는 마지막 시각. 서버 한도 시각보다 1분 앞에 둔다.
    func confirmUpperBound(for l: LiveState) -> Date? {
        guard let started = l.startedAt else { return nil }
        return started.addingTimeInterval(SessionRules.limitHours(for: l.category) * 3600 - 60)
    }

    func commitConfirmEnd() {
        guard let before = live, before.phase == .needsConfirmation, let id = before.serverID, !isBusy else { return }
        let chosen = confirmDate
        route = .none
        live = nil
        isBusy = true
        mutationTask = Task {
            defer { self.isBusy = false }
            do {
                let pair: SessionPair = try await self.backend.rpc("confirm_end", [
                    "p_session_id": .string(id.uuidString.lowercased()),
                    "p_ended_at": .string(ISODate.string(chosen)),
                ])
                self.liveSession = nil
                self.lastEndedSession = pair.dto
                self.showToast("나중에 정정함으로 저장했어요")
            } catch {
                if self.live == nil { self.live = before; self.route = .confirmEnd }
                self.report(error, title: "종료 시각을 저장하지 못했어요")
            }
        }
    }

    // MARK: - 서버와 맞추기

    /// 앱이 켜질 때와 앞으로 돌아올 때 부른다. 서버의 진행 중 세션을 가져와 맞춘다.
    public func refresh() async { await refresh(force: false) }

    func refresh(force: Bool) async {
        // 방금 눌러 응답을 기다리는 임시 상태나 전송 중인 변경은 덮어쓰지 않는다.
        if !force && (isBusy || live?.awaitingServer == true) { return }
        do {
            let found: SessionPair? = try await backend.rpc("get_my_live_session", [:])
            if let pair = found {
                adopt(pair, clientID: live?.clientID)
            } else if live?.serverID != nil {
                // 다른 기기에서 끝났다.
                live = nil
                liveSession = nil
            } else if live == nil {
                try await findNeedsConfirmation()
            }
        } catch {
            // 조용히 둔다. 기존 화면 상태를 유지한다.
        }
    }

    /// get_my_live_session이 종료 확인 필요 세션을 주지 않는 경우를 대비해 최근 목록에서 한 번 찾는다.
    private func findNeedsConfirmation() async throws {
        struct RawPage: Decodable { let items: [SessionPair] }
        let page: RawPage = try await backend.rpc("list_my_sessions", [
            "p_cursor": .null, "p_limit": .number(5), "p_thread_id": .null,
        ])
        if let pair = page.items.first(where: { $0.snapshot.phase == .needsConfirmation }) {
            adopt(pair, clientID: nil)
        }
    }

    /// 앱을 다시 열었을 때: 보내지 못한 것이 있으면 다시 보내고 서버 상태를 가져온다.
    public func resume() async {
        scheduleFlush()
        await refresh()
    }

    public func retryPending() { scheduleFlush() }

    private func adopt(_ pair: SessionPair, clientID: UUID?) {
        let s = pair.snapshot
        let phase = s.phase
        if phase == .ended {
            live = nil
            liveSession = nil
            return
        }
        let prev = live
        let state = LiveState(
            clientID: prev?.clientID ?? clientID ?? s.id,
            serverID: s.id,
            category: s.primaryCategory,
            shareTitle: s.shareTitle,
            joinedWithName: prev?.joinedWithName,
            phase: phase,
            clock: SessionClock(snapshot: s, uptime: uptime()),
            startedAt: s.startedAt,
            isOfflineStart: s.offlineStartedAt != nil,
            captureMode: s.captureMode,
            todoID: prev?.todoID)
        live = state
        liveSession = pair.dto
        if phase == .needsConfirmation {
            confirmDate = confirmUpperBound(for: state) ?? now()
            route = .confirmEnd
        }
    }

    /// 서버 세션 id가 필요한 변경 앞에서: 시작 요청이 아직 가는 중이면 기다린다. 연결이 없어 대기 중이면 오류.
    private func resolveServerID() async throws -> UUID {
        if let id = live?.serverID { return id }
        await startTask?.value
        if let id = live?.serverID { return id }
        throw BackendError(code: "network")
    }

    // MARK: - 오프라인 대기열

    private func restoreProvisionalFromPending() {
        guard live == nil, let p = pending.starts.first else { return }
        var l = provisionalState(for: p, offline: true)
        // 앱을 껐다 켠 경우의 임시 표시일 뿐이다. 서버가 받으면 서버 값으로 바뀐다.
        let age = max(0, now().timeIntervalSince(p.tappedAt))
        l.clock = SessionClock(base: age, anchorUptime: uptime(), running: true)
        live = l
    }

    private func persist() { store.save(pending) }

    private func scheduleFlush() {
        guard flushTask == nil, !pending.isEmpty else { return }
        flushTask = Task { [weak self] in
            var delay: TimeInterval = 2
            while let self, !Task.isCancelled {
                await self.flushStarts()
                await self.flushPhotos()
                if self.pending.isEmpty { break }
                await self.sleeper(delay)
                delay = min(delay * 2, 60)
            }
            self?.flushTask = nil
        }
    }

    @ObservationIgnored private var flushingStarts = false
    @ObservationIgnored private var flushingPhotos = false

    private func flushStarts() async {
        guard !flushingStarts else { return }
        flushingStarts = true
        defer { flushingStarts = false }
        for p in pending.starts {
            let age = now().timeIntervalSince(p.tappedAt)
            if age > SessionRules.offlineMaxAge {
                pending.starts.removeAll { $0.clientID == p.clientID }
                persist()
                removePhotoFiles(clientID: p.clientID)
                if live?.clientID == p.clientID { live = nil }
                alert = AlertInfo(title: "기록을 보내지 못했어요", message: "오프라인으로 시작한 지 12시간이 지나 서버가 받을 수 없어요.")
                continue
            }
            // 기기 시계가 뒤로 가서 시작 시각이 미래가 됐다면 서버 시각에 맡긴다.
            let offlineAt: Date? = age >= 0 ? p.tappedAt : nil
            do {
                let pair: SessionPair = try await backend.rpc("start_session", p.params(offlineStartedAt: offlineAt))
                pending.starts.removeAll { $0.clientID == p.clientID }
                persist()
                adopt(pair, clientID: p.clientID)
                queuePhotoIfNeeded(p, sessionID: pair.snapshot.id)
            } catch {
                switch classify(error) {
                case .transient, .cancelled:
                    return
                case .permanent(let code):
                    pending.starts.removeAll { $0.clientID == p.clientID }
                    persist()
                    await handleStartRejected(p, code: code)
                }
            }
        }
    }

    // MARK: - 사진 올리기 (세션 시작을 기다리게 하지 않는다)

    private func queuePhotoIfNeeded(_ p: PendingStart, sessionID: UUID) {
        guard p.hasPhoto else { return }
        pending.photos.removeAll { $0.clientID == p.clientID }
        pending.photos.append(PendingPhoto(sessionID: sessionID, clientID: p.clientID))
        persist()
        photoUploadTask = Task { await self.flushPhotos() }
        scheduleFlush()
    }

    private func flushPhotos() async {
        guard !flushingPhotos, let userID = backend.currentUserID else { return }
        flushingPhotos = true
        defer { flushingPhotos = false }
        for item in pending.photos {
            let dir = photoDirectory(for: item.clientID)
            let full = dir.appendingPathComponent("full.heic")
            let thumb = dir.appendingPathComponent("thumb.heic")
            let fm = FileManager.default
            guard fm.fileExists(atPath: full.path), fm.fileExists(atPath: thumb.path) else {
                dropPhoto(item)
                continue
            }
            let fullPath = PhotoPaths.full(userID: userID, sessionID: item.sessionID)
            let thumbPath = PhotoPaths.thumb(userID: userID, sessionID: item.sessionID)
            do {
                async let a: Void = backend.upload(path: fullPath, fileURL: full, contentType: "image/heic")
                async let b: Void = backend.upload(path: thumbPath, fileURL: thumb, contentType: "image/heic")
                try await a
                try await b
                let pair: SessionPair = try await backend.rpc("attach_session_photo", [
                    "p_session_id": .string(item.sessionID.uuidString.lowercased()),
                    "p_photo_path": .string(fullPath),
                    "p_thumb_path": .string(thumbPath),
                ])
                dropPhoto(item)
                if live?.serverID == item.sessionID, pair.snapshot.phase != .ended { liveSession = pair.dto }
            } catch {
                if case .cancelled = classify(error) { return }
                // 연결 문제는 계속 다시 시도하고, 그 밖의 오류는 5번까지만.
                var attempts = item.attempts
                if case .permanent = classify(error) { attempts += 1 }
                if attempts >= 5 {
                    dropPhoto(item)
                } else if let i = pending.photos.firstIndex(where: { $0.clientID == item.clientID }) {
                    pending.photos[i].attempts = attempts
                    persist()
                }
            }
        }
    }

    private func dropPhoto(_ item: PendingPhoto) {
        pending.photos.removeAll { $0.clientID == item.clientID }
        persist()
        removePhotoFiles(clientID: item.clientID)
    }

    private func removePhotoFiles(clientID: UUID) {
        try? FileManager.default.removeItem(at: photoDirectory(for: clientID))
    }

    private func removePhotoFilesIfNoPending(clientID: UUID) {
        if !pending.photos.contains(where: { $0.clientID == clientID }) { removePhotoFiles(clientID: clientID) }
    }

    // MARK: - 보조

    private enum Failure { case cancelled, transient, permanent(String) }

    private func classify(_ error: Error) -> Failure {
        if error is CancellationError { return .cancelled }
        if let e = error as? BackendError {
            return (e.code == "network" || e.code == "timeout") ? .transient : .permanent(e.code)
        }
        if error is URLError { return .transient }
        return .permanent("unknown")
    }

    private func report(_ error: Error, title: String) {
        if case .cancelled = classify(error) { return }
        let code: String
        switch classify(error) {
        case .transient: code = "network"
        case .permanent(let c): code = c
        case .cancelled: return
        }
        alert = AlertInfo(title: title, message: ErrorText.message(for: code))
    }

    private func showToast(_ text: String) {
        toast = text
        Task { [sleeper] in
            await sleeper(2.5)
            if self.toast == text { self.toast = nil }
        }
    }

    /// 테스트용: 진행 중인 뒤쪽 작업이 모두 끝날 때까지 기다린다.
    func waitUntilIdle() async {
        await startTask?.value
        await mutationTask?.value
        await photoUploadTask?.value
        await flushTask?.value
    }

    func waitForStart() async { await startTask?.value }
    func waitForPhotoUpload() async { await photoUploadTask?.value }
    /// 테스트용: 다시 보내기 반복을 멈추고 끝날 때까지 기다린다.
    func cancelFlush() async {
        let t = flushTask
        t?.cancel()
        await t?.value
        flushTask = nil
    }

    var pendingState: PendingState { pending }

    #if canImport(Network)
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.retryPending() }
        }
        monitor.start(queue: DispatchQueue(label: "pondu.session.path"))
        pathMonitor = monitor
    }
    #else
    private func startPathMonitor() {}
    #endif
}
