import Foundation
import Observation
import PonduCore

/// 세션 목록(20개씩 커서). threadID가 있으면 그 이어가는 일의 이력만.
@MainActor
@Observable
final class SessionListModel {
    static let pageSize = 20

    private(set) var items: [RecordSession] = []
    private(set) var nextCursor: String?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorCode: String?

    private let backend: Backend
    let threadID: UUID?
    @ObservationIgnored private var inFlight = false

    init(backend: Backend, threadID: UUID? = nil) {
        self.backend = backend
        self.threadID = threadID
    }

    /// 캐시로 먼저 그린 첫 쪽을 넣는다.
    func seed(_ page: RecordPage) {
        guard !hasLoaded else { return }
        items = page.items
        nextCursor = page.nextCursor
    }

    func applyFirstPage(_ page: RecordPage) {
        items = page.items
        nextCursor = page.nextCursor
        hasLoaded = true
        errorCode = nil
    }

    func fetchPage(cursor: String?) async throws -> RecordPage {
        try await backend.rpc("list_my_sessions", [
            "p_cursor": cursor.map { .string($0) } ?? .null,
            "p_limit": .number(Double(Self.pageSize)),
            "p_thread_id": threadID.map { .string($0.uuidString.lowercased()) } ?? .null,
        ])
    }

    func reload() async {
        guard !inFlight else { return }
        inFlight = true; isLoading = true
        defer { inFlight = false; isLoading = false }
        do {
            applyFirstPage(try await fetchPage(cursor: nil))
        } catch {
            errorCode = (error as? BackendError)?.code ?? "unknown"
            hasLoaded = true
        }
    }

    /// 마지막 쪽 근처 행이 보이면 다음 20개를 받는다.
    func loadMoreIfNeeded(current: RecordSession) async {
        guard let cursor = nextCursor, !inFlight, items.suffix(5).contains(where: { $0.id == current.id }) else { return }
        inFlight = true; isLoading = true
        defer { inFlight = false; isLoading = false }
        do {
            let page = try await fetchPage(cursor: cursor)
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            nextCursor = page.nextCursor
        } catch {
            errorCode = (error as? BackendError)?.code ?? "unknown"
        }
    }
}
