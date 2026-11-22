import Foundation
import Observation
import PonduCore

/// 피드에 그리는 카드 한 장. 반응·한마디 수는 누르는 즉시 바뀌어야 해서 DTO 밖에 따로 둔다.
struct FeedItem: Identifiable {
    let card: FeedCardDTO
    var myReaction: String?
    var reactionCount: Int
    var commentCount: Int

    var id: UUID { card.sessionId }

    init(card: FeedCardDTO) {
        self.card = card
        self.myReaction = card.myReaction
        self.reactionCount = card.reactionCount
        self.commentCount = card.commentCount
    }

    var isActive: Bool { card.status == .live || card.status == .paused }
}

/// 함께 탭의 피드. 화면 하나에 서버 함수 하나(`get_feed`)로 그린다.
/// 정렬은 서버가 준 시간순 그대로이고, 시간 합계로 위아래를 바꾸지 않는다.
@MainActor
@Observable
final class FeedModel {
    enum Scope: Equatable {
        case friends
        case crew(UUID)
    }

    enum Phase: Equatable {
        case loading
        case ready
        case failed
    }

    static let pageSize = 20
    static let reactionKind = "cheer"   // `수고했어`

    private(set) var scope: Scope = .friends
    private(set) var items: [FeedItem] = []
    private(set) var phase: Phase = .loading
    private(set) var isLoadingMore = false
    private(set) var crews: [CrewDTO] = []
    var toast: String?

    /// 같이 하기를 누르면 시작 화면을 띄운다. 루트 뷰가 `deps.sessions.presentStart`를 넣는다.
    @ObservationIgnored var onJoin: (@MainActor (StartSessionRequest) -> Void)?

    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private var nextCursor: String?
    @ObservationIgnored private var seen: Set<UUID> = []
    @ObservationIgnored private var hiddenSessions: Set<UUID> = []
    @ObservationIgnored private var hiddenAuthors: Set<UUID> = []
    @ObservationIgnored private var reactionInFlight: Set<UUID> = []
    /// 범위를 바꾸거나 새로 고칠 때 늦게 도착한 이전 응답을 버리기 위한 번호.
    @ObservationIgnored private var generation = 0

    init(backend: Backend) {
        self.backend = backend
    }

    var currentUserID: UUID? { backend.currentUserID }
    var hasMore: Bool { nextCursor != nil }

    // MARK: 불러오기

    /// 첫 화면. 피드와 내 크루 목록은 서로 무관하므로 동시에 요청한다.
    func reload() async {
        generation += 1
        let gen = generation
        let backend = self.backend
        let params = Self.feedParams(cursor: nil, scope: scope)
        if items.isEmpty { phase = .loading }

        async let page: Page<FeedCardDTO> = backend.rpc("get_feed", params)
        async let crewList: [CrewDTO]? = try? await backend.rpc("list_my_crews", [:])

        do {
            let result = try await page
            let crewResult = await crewList
            guard gen == generation else { return }
            seen = []
            items = []
            append(result.items)
            nextCursor = result.nextCursor
            if let crewResult { crews = crewResult }
            phase = .ready
        } catch {
            _ = await crewList
            guard gen == generation else { return }
            if items.isEmpty {
                phase = .failed
            } else {
                toast = TogetherText.message(for: error)
            }
        }
    }

    func setScope(_ newScope: Scope) async {
        guard newScope != scope else { return }
        scope = newScope
        items = []          // 뼈대 화면을 바로 보여 준다
        seen = []
        nextCursor = nil
        phase = .loading
        await reload()
    }

    /// 목록 끝 가까이 온 행이 나타날 때 부른다.
    func loadMoreIfNeeded(current item: FeedItem) async {
        guard items.suffix(5).contains(where: { $0.id == item.id }) else { return }
        await loadMore()
    }

    func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore, phase == .ready else { return }
        isLoadingMore = true
        let gen = generation
        defer { isLoadingMore = false }
        do {
            let page: Page<FeedCardDTO> = try await backend.rpc("get_feed", Self.feedParams(cursor: cursor, scope: scope))
            guard gen == generation else { return }
            append(page.items)
            nextCursor = page.nextCursor
        } catch {
            guard gen == generation else { return }
            toast = TogetherText.message(for: error)
        }
    }

    private func append(_ cards: [FeedCardDTO]) {
        for card in cards {
            // 같은 세션이 페이지 경계에서 두 번 오더라도 한 번만 그린다.
            guard seen.insert(card.sessionId).inserted else { continue }
            if hiddenSessions.contains(card.sessionId) || hiddenAuthors.contains(card.author.id) { continue }
            items.append(FeedItem(card: card))
        }
    }

    private static func feedParams(cursor: String?, scope: Scope) -> [String: JSONValue] {
        var groupID: UUID?
        if case .crew(let id) = scope { groupID = id }
        return [
            "p_cursor": TogetherParam.optionalString(cursor),
            "p_limit": .number(Double(pageSize)),
            "p_group_id": TogetherParam.optionalID(groupID),
        ]
    }

    // MARK: 반응 (누르는 즉시 반영, 실패하면 되돌림)

    func toggleReaction(on sessionID: UUID) async {
        guard let index = items.firstIndex(where: { $0.id == sessionID }),
              !reactionInFlight.contains(sessionID) else { return }
        reactionInFlight.insert(sessionID)
        defer { reactionInFlight.remove(sessionID) }

        let before = items[index]
        let newKind: String? = before.myReaction == nil ? Self.reactionKind : nil
        items[index].myReaction = newKind
        items[index].reactionCount = max(0, before.reactionCount + (newKind == nil ? -1 : 1))

        do {
            try await backend.rpcVoid("set_reaction", [
                "p_session_id": TogetherParam.id(sessionID),
                "p_kind": TogetherParam.optionalString(newKind),
            ])
        } catch {
            if let now = items.firstIndex(where: { $0.id == sessionID }) {
                items[now].myReaction = before.myReaction
                items[now].reactionCount = before.reactionCount
            }
            toast = TogetherText.message(for: error)
        }
    }

    /// 한마디 화면에서 수가 바뀌면 카드의 수도 맞춘다.
    func adjustCommentCount(sessionID: UUID, by delta: Int) {
        guard let index = items.firstIndex(where: { $0.id == sessionID }) else { return }
        items[index].commentCount = max(0, items[index].commentCount + delta)
    }

    // MARK: 같이 하기

    func joinRequest(for card: FeedCardDTO) -> StartSessionRequest {
        var request = StartSessionRequest()
        request.category = card.primaryCategory
        request.title = card.shareTitle
        request.joinedSessionID = card.sessionId
        request.joinedWithName = card.author.displayName
        return request
    }

    func join(_ card: FeedCardDTO) {
        onJoin?(joinRequest(for: card))
    }

    func canJoin(_ item: FeedItem) -> Bool {
        item.isActive && item.card.author.id != backend.currentUserID
    }

    // MARK: 신고·차단 (누르는 즉시 숨김)

    func report(sessionID: UUID, reason: String) async {
        guard let index = items.firstIndex(where: { $0.id == sessionID }) else { return }
        let removed = items.remove(at: index)
        hiddenSessions.insert(sessionID)
        do {
            try await backend.rpcVoid("report_session", [
                "p_session_id": TogetherParam.id(sessionID),
                "p_reason": .string(reason),
            ])
            toast = "신고했어요. 이 기록은 더 이상 보이지 않아요."
        } catch {
            hiddenSessions.remove(sessionID)
            items.insert(removed, at: min(index, items.count))
            toast = TogetherText.message(for: error)
        }
    }

    func block(author: ProfileCard) async {
        let authorID = author.id
        let snapshot = items
        hiddenAuthors.insert(authorID)
        items.removeAll { $0.card.author.id == authorID }
        do {
            try await backend.rpcVoid("block_user", ["p_user_id": TogetherParam.id(authorID)])
            toast = "\(author.displayName)님을 차단했어요."
        } catch {
            hiddenAuthors.remove(authorID)
            items = snapshot
            toast = TogetherText.message(for: error)
        }
    }
}
