import Foundation
import PonduCore

/// 계약 3절의 JSON 모양으로 만든 시험용 값. DTO 생성자에 기대지 않고 JSON을 디코딩해서 만든다.
enum Fixtures {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func profile(id: UUID = UUID(), name: String = "가온", handle: String = "gaon") -> [String: Any] {
        ["id": id.uuidString.lowercased(), "handle": handle, "display_name": name,
         "avatar_path": NSNull(), "department_name": "컴퓨터학과"]
    }

    static func card(id: UUID = UUID(), authorID: UUID = UUID(), authorName: String = "가온",
                     status: String = "live", myReaction: String? = nil,
                     reactionCount: Int = 0, commentCount: Int = 0,
                     shareTitle: String? = "DB 과제", groupName: String? = nil) -> [String: Any] {
        [
            "session_id": id.uuidString.lowercased(),
            "author": profile(id: authorID, name: authorName),
            "thread_id": NSNull(),
            "share_title": shareTitle.map { $0 as Any } ?? NSNull(),
            "primary_category": "study",
            "started_at": "2026-11-22T06:12:00Z",
            "ended_at": NSNull(),
            "status": status,
            "duration_seconds": 1800,
            "progress_note": "1번 문제 접근법 보는 중",
            "photo_path": NSNull(),
            "photo_thumb_path": NSNull(),
            "capture_mode": "no_photo",
            "end_corrected": false,
            "offline_started": false,
            "joined_with": NSNull(),
            "reaction_count": reactionCount,
            "my_reaction": myReaction.map { $0 as Any } ?? NSNull(),
            "comment_count": commentCount,
            "group_id": groupName == nil ? (NSNull() as Any) : ("33333333-3333-3333-3333-333333333333" as Any),
            "group_name": groupName.map { $0 as Any } ?? NSNull(),
        ]
    }

    static func page(_ cards: [[String: Any]], next: String?) -> Data {
        json(["items": cards, "next_cursor": next.map { $0 as Any } ?? NSNull()])
    }

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

struct RecordedCall: Sendable {
    let name: String
    let params: [String: JSONValue]
}

/// 서버 함수 호출을 흉내 내는 가짜 Backend. 함수 이름마다 응답을 등록해 쓴다.
final class FakeBackend: Backend, @unchecked Sendable {
    typealias Handler = @Sendable ([String: JSONValue]) async throws -> Data

    var currentUserID: UUID? = UUID()
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var recorded: [RecordedCall] = []

    func on(_ name: String, _ handler: @escaping Handler) {
        lock.lock(); handlers[name] = handler; lock.unlock()
    }

    var calls: [RecordedCall] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func calls(named name: String) -> [RecordedCall] { calls.filter { $0.name == name } }

    private func handle(_ name: String, _ params: [String: JSONValue]) async throws -> Data {
        let handler = lock.withLock {
            recorded.append(RecordedCall(name: name, params: params))
            return handlers[name]
        }
        guard let handler else { throw BackendError(code: "unknown") }
        return try await handler(params)
    }

    func rpc<T: Decodable>(_ name: String, _ params: [String: JSONValue]) async throws -> T {
        let data = try await handle(name, params)
        return try Fixtures.decoder.decode(T.self, from: data)
    }

    func rpcVoid(_ name: String, _ params: [String: JSONValue]) async throws {
        _ = try await handle(name, params)
    }

    func call<T: Decodable>(function: String, body: JSONValue) async throws -> T { throw BackendError(code: "unknown") }
    func stream(function: String, body: JSONValue) -> AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: BackendError(code: "unknown")) }
    }
    func upload(path: String, fileURL: URL, contentType: String) async throws {}
    func signedURL(path: String) async throws -> URL { URL(string: "https://example.invalid")! }
}
