import Foundation
import Observation
import PonduCore

/// 지난 기록 보기: 같은 작성자의 같은 이어가는 일 중 내가 볼 수 있는 기록(`get_thread_history`).
@MainActor
@Observable
final class ThreadHistoryModel {
    enum Phase: Equatable { case loading, ready, failed }

    private(set) var cards: [FeedCardDTO] = []
    private(set) var phase: Phase = .loading
    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let sessionID: UUID

    init(backend: Backend, sessionID: UUID) {
        self.backend = backend
        self.sessionID = sessionID
    }

    func load() async {
        phase = .loading
        do {
            let result: [FeedCardDTO] = try await backend.rpc("get_thread_history", [
                "p_session_id": TogetherParam.id(sessionID),
                "p_limit": .number(Double(FeedModel.pageSize)),
            ])
            var seen = Set<UUID>()
            cards = result.filter { seen.insert($0.sessionId).inserted }
            phase = .ready
        } catch {
            phase = .failed
        }
    }
}

/// 한마디. 보내면 바로 목록에 보이고, 실패하면 빼고 입력을 되돌려 준다.
@MainActor
@Observable
final class CommentsModel {
    enum Phase: Equatable { case loading, ready, failed }

    private(set) var comments: [DisplayComment] = []
    private(set) var phase: Phase = .loading
    var draft = ""
    var toast: String?
    /// 카드의 한마디 수를 맞추려고 루트가 넣는다.
    @ObservationIgnored var onCountChange: (@MainActor (Int) -> Void)?

    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let sessionID: UUID
    @ObservationIgnored private let myName: String

    init(backend: Backend, sessionID: UUID, myName: String = "나") {
        self.backend = backend
        self.sessionID = sessionID
        self.myName = myName
    }

    var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func load() async {
        phase = .loading
        do {
            let result: [CommentDTO] = try await backend.rpc("list_comments", [
                "p_session_id": TogetherParam.id(sessionID),
            ])
            comments = result.map {
                DisplayComment(id: $0.id, authorName: $0.author.displayName, body: $0.body,
                               createdAt: $0.createdAt, isPending: false)
            }
            phase = .ready
        } catch {
            phase = .failed
        }
    }

    func send(now: Date = Date()) async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let tempID = UUID()
        comments.append(DisplayComment(id: tempID, authorName: myName, body: body, createdAt: now, isPending: true))
        draft = ""
        onCountChange?(1)
        do {
            let saved: CommentDTO = try await backend.rpc("add_comment", [
                "p_session_id": TogetherParam.id(sessionID),
                "p_body": .string(body),
            ])
            if let i = comments.firstIndex(where: { $0.id == tempID }) {
                comments[i] = DisplayComment(id: saved.id, authorName: saved.author.displayName, body: saved.body,
                                             createdAt: saved.createdAt, isPending: false)
            }
        } catch {
            comments.removeAll { $0.id == tempID }
            if draft.isEmpty { draft = body }
            onCountChange?(-1)
            toast = TogetherText.message(for: error)
        }
    }
}
