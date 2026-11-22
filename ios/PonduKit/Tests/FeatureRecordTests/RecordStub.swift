import Foundation
import PonduCore

/// 테스트용 가짜 Backend. 함수 이름별 응답을 등록하고 호출 기록을 남긴다.
final class RecordStubBackend: Backend, @unchecked Sendable {
    enum Reply { case json(Any), error(BackendError) }
    struct Call { let name: String; let params: [String: JSONValue] }

    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]
    private(set) var calls: [Call] = []
    var currentUserID: UUID? { UUID(uuidString: "11111111-2222-3333-4444-555555555555") }

    func on(_ name: String, _ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        replies[name, default: []].append(reply)
    }
    func calls(_ name: String) -> [Call] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.name == name }
    }

    func rpc<T: Decodable>(_ name: String, _ params: [String: JSONValue]) async throws -> T {
        let reply: Reply = try {
            lock.lock(); defer { lock.unlock() }
            calls.append(Call(name: name, params: params))
            guard var q = replies[name], !q.isEmpty else { throw BackendError(code: "unknown") }
            let first = q.removeFirst()
            if q.isEmpty { q = [first] }
            replies[name] = q
            return first
        }()
        switch reply {
        case .error(let e): throw e
        case .json(let obj):
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])
            return try RecordStubBackend.decoder.decode(T.self, from: data)
        }
    }
    func rpcVoid(_ name: String, _ params: [String: JSONValue]) async throws {}
    func call<T: Decodable>(function: String, body: JSONValue) async throws -> T { throw BackendError(code: "unknown") }
    func stream(function: String, body: JSONValue) -> AsyncThrowingStream<ServerEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func upload(path: String, fileURL: URL, contentType: String) async throws {}
    func signedURL(path: String) async throws -> URL { URL(string: "https://example.invalid/\(path)")! }

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

enum RecordFixture {
    static func session(_ n: Int, status: String = "ended", captureMode: String = "no_photo",
                        endCorrected: Bool = false, offline: Bool = false) -> [String: Any] {
        [
            "id": String(format: "aaaaaaaa-0000-0000-0000-%012d", n),
            "thread_id": NSNull(), "primary_category": "study",
            "started_at": "2026-11-20T01:00:00Z", "ended_at": "2026-11-20T02:00:00Z",
            "duration_seconds": 3600, "status": status, "capture_mode": captureMode,
            "share_title": NSNull(), "progress_note": NSNull(), "end_corrected": endCorrected,
            "offline_started_at": offline ? "2026-11-20T00:59:00Z" : NSNull(),
        ]
    }
    static func page(_ range: Range<Int>, next: String?) -> [String: Any] {
        ["items": range.map { session($0) }, "next_cursor": next as Any? ?? NSNull()]
    }
    static let summary: [String: Any] = [
        "days": [["day": "2026-11-20", "seconds": 3600, "session_count": 2, "by_category": [String: Int]()]],
        "by_category": [["category": "study", "seconds": 3600]],
        "threads": [["thread_id": "bbbbbbbb-0000-0000-0000-000000000001", "title": "DB 과제", "seconds": 3600, "last_at": "2026-11-20T02:00:00Z"]],
    ]
}
