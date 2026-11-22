import Foundation
import Observation
import PonduCore

/// 기록 탭 모델. 기기에 저장한 값으로 먼저 그리고 서버 값으로 갱신한다.
/// 화면 하나에 서버 함수 하나씩(요약 1, 목록 1)을 async let으로 동시에 받는다.
@MainActor
@Observable
final class RecordModel {
    private(set) var summary: RecordSummary?
    private(set) var isRefreshing = false
    private(set) var errorCode: String?
    /// 저장해 둔 값만 보여 주는 중(서버 값은 아직)
    private(set) var isShowingCached = false
    let sessions: SessionListModel

    private let backend: Backend
    private let cache: RecordCaching
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let timeZoneID: String
    @ObservationIgnored private var inFlight = false

    init(backend: Backend, cache: RecordCaching = FileRecordCache(), now: @escaping @Sendable () -> Date = { Date() },
         calendar: Calendar = .current) {
        self.backend = backend
        self.cache = cache
        self.now = now
        self.calendar = calendar
        self.timeZoneID = calendar.timeZone.identifier
        self.sessions = SessionListModel(backend: backend)
    }

    private var userKey: String { backend.currentUserID?.uuidString.lowercased() ?? "anonymous" }

    var hasContent: Bool { summary != nil }

    var heatmapColumns: [[Heatmap.Cell]] {
        Heatmap.columns(days: summary?.days ?? [], today: now(), calendar: calendar)
    }

    func load() async {
        if summary == nil, let cached = cache.load(userKey: userKey) {
            summary = cached.summary
            sessions.seed(cached.firstPage)
            isShowingCached = true
        }
        await refresh()
    }

    func refresh() async {
        guard !inFlight else { return }
        inFlight = true; isRefreshing = true
        defer { inFlight = false; isRefreshing = false }
        let range = Heatmap.range(today: now(), calendar: calendar)
        let from = Heatmap.dayString(range.from, calendar: calendar)
        let to = Heatmap.dayString(range.to, calendar: calendar)
        do {
            async let summaryResult: RecordSummary = backend.rpc("get_record_summary", [
                "p_from": .string(from), "p_to": .string(to), "p_tz": .string(timeZoneID),
            ])
            async let pageResult: RecordPage = sessions.fetchPage(cursor: nil)
            let (s, page) = try await (summaryResult, pageResult)
            summary = s
            sessions.applyFirstPage(page)
            isShowingCached = false
            errorCode = nil
            cache.save(RecordSnapshot(summary: s, firstPage: page, savedAt: now()), userKey: userKey)
        } catch {
            // 저장해 둔 값이 있으면 그대로 두고, 없을 때만 오류를 보여 준다.
            if summary == nil { errorCode = (error as? BackendError)?.code ?? "unknown" }
        }
    }
}
