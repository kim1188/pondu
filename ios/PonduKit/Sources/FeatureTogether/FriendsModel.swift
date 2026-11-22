import Foundation
import Observation
import PonduCore

/// 친구 목록, 받은 요청, 아이디 검색.
@MainActor
@Observable
final class FriendsModel {
    enum Phase: Equatable { case loading, ready, failed }
    enum SearchPhase: Equatable { case idle, waiting, searching, done }

    private(set) var friends: [ProfileCard] = []
    private(set) var incoming: [ProfileCard] = []
    private(set) var outgoing: [ProfileCard] = []
    private(set) var phase: Phase = .loading

    var query = ""
    private(set) var results: [ProfileCard] = []
    private(set) var searchPhase: SearchPhase = .idle
    var toast: String?

    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0

    /// - Parameter debounce: 입력이 멈춘 뒤 기다리는 시간. 제품은 0.3초, 시험은 짧게 준다.
    init(backend: Backend, debounce: Duration = .milliseconds(300)) {
        self.backend = backend
        self.debounce = debounce
    }

    // MARK: 목록

    /// 친구 목록과 요청 목록은 서로 무관하므로 동시에 받는다.
    func load() async {
        if friends.isEmpty && incoming.isEmpty { phase = .loading }
        let backend = self.backend
        async let friendList: [ProfileCard] = backend.rpc("list_friends", [:])
        async let requestList: FriendRequestsDTO = backend.rpc("list_friend_requests", [:])
        do {
            let (f, r) = try await (friendList, requestList)
            friends = f
            incoming = r.incoming
            outgoing = r.outgoing
            phase = .ready
        } catch {
            if friends.isEmpty && incoming.isEmpty { phase = .failed } else { toast = TogetherText.message(for: error) }
        }
    }

    var hasNoRelations: Bool { phase == .ready && friends.isEmpty && incoming.isEmpty && outgoing.isEmpty }

    // MARK: 검색 (입력이 멈춘 뒤 요청, 이전 요청은 취소)

    func queryChanged(_ text: String) {
        searchTask?.cancel()
        searchGeneration += 1
        let gen = searchGeneration
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            results = []
            searchPhase = .idle
            return
        }
        searchPhase = .waiting
        let wait = debounce
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: wait) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.runSearch(trimmed, generation: gen)
        }
    }

    private func runSearch(_ text: String, generation gen: Int) async {
        guard gen == searchGeneration else { return }
        searchPhase = .searching
        do {
            let found: [ProfileCard] = try await backend.rpc("search_profiles", [
                "p_query": .string(text),
                "p_limit": .number(20),
            ])
            guard gen == searchGeneration, !Task.isCancelled else { return }
            results = found
            searchPhase = .done
        } catch {
            guard gen == searchGeneration, !Task.isCancelled else { return }
            searchPhase = .done
            if !(error is CancellationError) { toast = TogetherText.message(for: error) }
        }
    }

    enum Relation { case none, friend, requested, incoming }

    func relation(to id: UUID) -> Relation {
        if friends.contains(where: { $0.id == id }) { return .friend }
        if outgoing.contains(where: { $0.id == id }) { return .requested }
        if incoming.contains(where: { $0.id == id }) { return .incoming }
        return .none
    }

    // MARK: 요청·수락·삭제 (누르는 즉시 반영, 실패하면 되돌림)

    func sendRequest(to user: ProfileCard) async {
        guard relation(to: user.id) == .none else { return }
        outgoing.append(user)
        do {
            try await backend.rpcVoid("send_friend_request", ["p_user_id": TogetherParam.id(user.id)])
        } catch {
            outgoing.removeAll { $0.id == user.id }
            toast = TogetherText.message(for: error)
        }
    }

    func respond(to user: ProfileCard, accept: Bool) async {
        guard incoming.contains(where: { $0.id == user.id }) else { return }
        let incomingBefore = incoming
        let friendsBefore = friends
        incoming.removeAll { $0.id == user.id }
        if accept { friends.insert(user, at: 0) }
        do {
            try await backend.rpcVoid("respond_friend_request", [
                "p_user_id": TogetherParam.id(user.id),
                "p_accept": .bool(accept),
            ])
        } catch {
            incoming = incomingBefore
            friends = friendsBefore
            toast = TogetherText.message(for: error)
        }
    }

    func removeFriend(_ user: ProfileCard) async {
        let before = friends
        friends.removeAll { $0.id == user.id }
        do {
            try await backend.rpcVoid("remove_friend", ["p_user_id": TogetherParam.id(user.id)])
        } catch {
            friends = before
            toast = TogetherText.message(for: error)
        }
    }

    func block(_ user: ProfileCard) async {
        let friendsBefore = friends, incomingBefore = incoming, outgoingBefore = outgoing, resultsBefore = results
        friends.removeAll { $0.id == user.id }
        incoming.removeAll { $0.id == user.id }
        outgoing.removeAll { $0.id == user.id }
        results.removeAll { $0.id == user.id }
        do {
            try await backend.rpcVoid("block_user", ["p_user_id": TogetherParam.id(user.id)])
            toast = "\(user.displayName)님을 차단했어요."
        } catch {
            friends = friendsBefore; incoming = incomingBefore; outgoing = outgoingBefore; results = resultsBefore
            toast = TogetherText.message(for: error)
        }
    }
}
