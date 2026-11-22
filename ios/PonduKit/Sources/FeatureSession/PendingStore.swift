import Foundation
import PonduCore

/// 서버에 아직 보내지 못한 시작 한 건. 같은 clientID로 다시 보내도 서버에는 한 번만 만들어진다.
struct PendingStart: Codable, Equatable, Identifiable {
    var clientID: UUID
    var category: String
    var captureMode: String
    var visibility: String
    /// 크루 공개일 때만 있다. 이 필드가 생기기 전에 저장된 대기열에는 없으므로 옵셔널이다.
    var groupID: UUID?
    var threadID: UUID?
    var todoID: UUID?
    var planBlockID: UUID?
    var joinedSessionID: UUID?
    var joinedWithName: String?
    var shareTitle: String?
    var tags: [String] = []
    /// 사용자가 시작을 누른 기기 시각. 서버가 받아 주는 유일한 클라이언트 시각(p_offline_started_at).
    var tappedAt: Date
    var hasPhoto: Bool

    var id: UUID { clientID }

    func params(offlineStartedAt: Date?) -> [String: JSONValue] {
        func uuid(_ v: UUID?) -> JSONValue { v.map { .string($0.uuidString.lowercased()) } ?? .null }
        return [
            "p_client_id": .string(clientID.uuidString.lowercased()),
            "p_primary_category": .string(category),
            "p_capture_mode": .string(captureMode),
            "p_visibility": .string(visibility),
            "p_group_id": uuid(groupID),
            "p_thread_id": uuid(threadID),
            "p_todo_id": uuid(todoID),
            "p_plan_block_id": uuid(planBlockID),
            "p_tags": .array(tags.map { .string($0) }),
            "p_share_title": shareTitle.map { .string($0) } ?? .null,
            "p_joined_session_id": uuid(joinedSessionID),
            "p_offline_started_at": offlineStartedAt.map { .string(ISODate.string($0)) } ?? .null,
        ]
    }
}

/// 시작은 됐지만 사진이 아직 올라가지 않은 건. 파일은 photosDirectory/<clientID>/ 에 있다.
struct PendingPhoto: Codable, Equatable {
    var sessionID: UUID
    var clientID: UUID
    var attempts: Int = 0
}

struct PendingState: Codable, Equatable {
    var starts: [PendingStart] = []
    var photos: [PendingPhoto] = []
    var isEmpty: Bool { starts.isEmpty && photos.isEmpty }
}

protocol PendingStoring {
    func load() -> PendingState
    func save(_ state: PendingState)
}

final class InMemoryPendingStore: PendingStoring {
    private var state = PendingState()
    func load() -> PendingState { state }
    func save(_ state: PendingState) { self.state = state }
}

/// 앱을 닫아도 남도록 Application Support에 JSON으로 둔다.
final class FilePendingStore: PendingStoring {
    private let url: URL
    init(url: URL) { self.url = url }

    static func standard() -> FilePendingStore {
        let dir = FilePendingStore.supportDirectory()
        return FilePendingStore(url: dir.appendingPathComponent("pending_sessions.json"))
    }

    static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Pondu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func load() -> PendingState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PendingState.self, from: data) else { return PendingState() }
        return state
    }

    func save(_ state: PendingState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum ISODate {
    static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
