import Foundation
import PonduCore

/// 테스트용 가짜 Backend. 함수 이름별로 응답(JSON 딕셔너리, 또는 던질 오류)을 등록하고 호출 기록을 남긴다.
final class StubBackend: Backend, @unchecked Sendable {
    enum Reply {
        case json(Any)
        case error(BackendError)
    }
    struct Call { let name: String; let params: [String: JSONValue] }

    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]
    private(set) var calls: [Call] = []
    private(set) var uploads: [(path: String, contentType: String)] = []
    var userID: UUID? = UUID(uuidString: "11111111-2222-3333-4444-555555555555")
    var currentUserID: UUID? { userID }
    var uploadError: BackendError?

    /// 같은 이름으로 여러 번 등록하면 앞에서부터 하나씩 쓰고, 마지막 것은 계속 쓴다.
    func on(_ name: String, _ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        replies[name, default: []].append(reply)
    }

    func count(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.name == name }.count
    }

    func lastParams(_ name: String) -> [String: JSONValue]? {
        lock.lock(); defer { lock.unlock() }
        return calls.last(where: { $0.name == name })?.params
    }

    func rpc<T: Decodable>(_ name: String, _ params: [String: JSONValue]) async throws -> T {
        let reply: Reply = try {
            lock.lock(); defer { lock.unlock() }
            calls.append(Call(name: name, params: params))
            guard var queue = replies[name], !queue.isEmpty else { throw BackendError(code: "unknown") }
            let first = queue.removeFirst()
            if queue.isEmpty { queue = [first] }   // 마지막 응답은 계속 쓴다
            replies[name] = queue
            return first
        }()
        switch reply {
        case .error(let e): throw e
        case .json(let obj):
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])
            return try StubBackend.decoder.decode(T.self, from: data)
        }
    }

    func rpcVoid(_ name: String, _ params: [String: JSONValue]) async throws {
        lock.withLock {
            calls.append(Call(name: name, params: params))
        }
    }

    func call<T: Decodable>(function: String, body: JSONValue) async throws -> T { throw BackendError(code: "unknown") }
    func stream(function: String, body: JSONValue) -> AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func upload(path: String, fileURL: URL, contentType: String) async throws {
        if let e = uploadError { throw e }
        lock.withLock {
            uploads.append((path, contentType))
        }
    }
    func signedURL(path: String) async throws -> URL { URL(string: "https://example.invalid/\(path)")! }

    /// 실제 앱의 디코더와 같은 규칙(snake_case 변환, ISO 8601)을 가정한다.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: s))
        }
        return d
    }()
}

enum Fixture {
    static let sessionID = "aaaaaaaa-0000-0000-0000-000000000001"
    static let userID = "11111111-2222-3333-4444-555555555555"

    static func session(id: String = sessionID, status: String = "live", category: String = "study",
                        startedAt: String = "2026-11-22T01:00:00Z", pausedAt: String? = nil,
                        pausedSeconds: Int = 0, duration: Int? = 0, outcome: String? = nil,
                        captureMode: String = "no_photo", offlineStartedAt: String? = nil,
                        todoID: String? = nil, groupID: String? = nil) -> [String: Any] {
        [
            "id": id, "user_id": userID, "thread_id": NSNull(), "todo_id": todoID as Any? ?? NSNull(), "plan_block_id": NSNull(),
            "joined_session_id": NSNull(), "primary_category": category, "tags": [String](),
            "started_at": startedAt, "ended_at": NSNull(), "paused_at": pausedAt as Any? ?? NSNull(),
            "paused_seconds": pausedSeconds, "duration_seconds": duration as Any? ?? NSNull(), "status": status,
            "outcome": outcome as Any? ?? NSNull(), "capture_mode": captureMode, "photo_path": NSNull(),
            "photo_thumb_path": NSNull(), "share_title": NSNull(), "progress_note": NSNull(), "visibility": "private",
            "end_corrected": false, "offline_started_at": offlineStartedAt as Any? ?? NSNull(),
            "group_id": groupID as Any? ?? NSNull(),
        ]
    }
}
