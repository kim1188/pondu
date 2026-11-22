import Foundation

/// 다른 흐름의 XCTest가 쓰는 가짜 Backend. 함수 이름별 응답을 등록하고 호출 기록을 남긴다.
///
/// ```swift
/// let backend = FakeBackend()
/// backend.register("get_feed", json: ["items": [], "next_cursor": nil])
/// backend.register("set_reaction") { params in .null }
/// backend.registerError("start_session", code: "session_already_active")
/// let page: Page<FeedCardDTO> = try await backend.rpc("get_feed", [:])
/// XCTAssertEqual(backend.calls(named: "get_feed").count, 1)
/// ```
public final class FakeBackend: Backend, @unchecked Sendable {
    public enum Kind: Equatable, Sendable {
        case rpc, rpcVoid, call, stream, upload, signedURL
    }

    public struct Call: Equatable, Sendable {
        public let kind: Kind
        /// rpc·rpcVoid는 서버 함수 이름, call·stream은 Edge 함수 이름, upload·signedURL은 경로.
        public let name: String
        /// rpc·rpcVoid의 인자, call·stream의 본문(`.object`로 감싼 것이 아니라 그대로).
        public let params: [String: JSONValue]
        public let body: JSONValue?

        public init(kind: Kind, name: String, params: [String: JSONValue] = [:], body: JSONValue? = nil) {
            self.kind = kind
            self.name = name
            self.params = params
            self.body = body
        }
    }

    public typealias Handler = @Sendable ([String: JSONValue]) throws -> JSONValue

    private enum Response {
        case handler(Handler)
        case error(BackendError)
    }

    private struct State {
        var userID: UUID?
        var responses: [String: Response] = [:]
        var calls: [Call] = []
        var streams: [String: [ServerEvent]] = [:]
        var streamErrors: [String: BackendError] = [:]
        var signedURLs: [String: URL] = [:]
        var uploadError: BackendError?
        var delayNanoseconds: UInt64 = 0
    }

    private let state: Locked<State>

    public init(userID: UUID? = UUID()) {
        self.state = Locked(State(userID: userID))
    }

    public var currentUserID: UUID? {
        get { state.withValue { $0.userID } }
        set { state.withValue { $0.userID = newValue } }
    }

    // MARK: 등록

    /// 고정 응답.
    public func register(_ name: String, json: JSONValue) {
        state.withValue { $0.responses[name] = .handler { _ in json } }
    }

    /// 인자를 보고 응답을 정한다.
    public func register(_ name: String, handler: @escaping Handler) {
        state.withValue { $0.responses[name] = .handler(handler) }
    }

    /// 인코딩 가능한 값(DTO, Page 등)을 서버 JSON 모양으로 바꿔 응답으로 쓴다.
    public func register<T: Encodable>(_ name: String, value: T) {
        let json = (try? PonduJSON.jsonValue(value)) ?? .null
        register(name, json: json)
    }

    public func registerError(_ name: String, code: String) {
        state.withValue { $0.responses[name] = .error(BackendError(code: code)) }
    }

    /// 스트리밍 함수가 보낼 이벤트. `data`는 JSON.
    public func registerStream(function: String, events: [(name: String, data: JSONValue)]) {
        let converted = events.map { event in
            ServerEvent(name: event.name, data: (try? JSONEncoder().encode(event.data)) ?? Data())
        }
        state.withValue { $0.streams[function] = converted }
    }

    public func registerStreamError(function: String, code: String) {
        state.withValue { $0.streamErrors[function] = BackendError(code: code) }
    }

    public func registerSignedURL(path: String, url: URL) {
        state.withValue { $0.signedURLs[path] = url }
    }

    public func setUploadError(code: String?) {
        state.withValue { $0.uploadError = code.map { BackendError(code: $0) } }
    }

    /// 모든 응답 앞에 지연을 둔다(누르는 즉시 반영 같은 동작을 시험할 때).
    public func setDelay(_ seconds: TimeInterval) {
        state.withValue { $0.delayNanoseconds = UInt64(seconds * 1_000_000_000) }
    }

    // MARK: 기록

    public var calls: [Call] { state.withValue { $0.calls } }

    public func calls(named name: String) -> [Call] {
        calls.filter { $0.name == name }
    }

    public func reset() {
        state.withValue {
            $0.calls = []
            $0.responses = [:]
            $0.streams = [:]
            $0.streamErrors = [:]
            $0.signedURLs = [:]
            $0.uploadError = nil
        }
    }

    // MARK: Backend

    public func rpc<T: Decodable>(_ name: String, _ params: [String: JSONValue]) async throws -> T {
        let json = try await respond(kind: .rpc, name: name, params: params, requireRegistered: true)
        return try Self.decode(json)
    }

    public func rpcVoid(_ name: String, _ params: [String: JSONValue]) async throws {
        _ = try await respond(kind: .rpcVoid, name: name, params: params, requireRegistered: false)
    }

    public func call<T: Decodable>(function: String, body: JSONValue) async throws -> T {
        let json = try await respond(kind: .call, name: function, params: [:], body: body, requireRegistered: true)
        return try Self.decode(json)
    }

    public func stream(function: String, body: JSONValue) -> AsyncThrowingStream<ServerEvent, Error> {
        let (events, error) = state.withValue { state -> ([ServerEvent], BackendError?) in
            state.calls.append(Call(kind: .stream, name: function, body: body))
            return (state.streams[function] ?? [], state.streamErrors[function])
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }

    public func upload(path: String, fileURL: URL, contentType: String) async throws {
        let error = state.withValue { state -> BackendError? in
            state.calls.append(Call(kind: .upload, name: path, params: ["content_type": .string(contentType), "file": .string(fileURL.path)]))
            return state.uploadError
        }
        if let error { throw error }
    }

    public func signedURL(path: String) async throws -> URL {
        let url = state.withValue { state -> URL? in
            state.calls.append(Call(kind: .signedURL, name: path))
            return state.signedURLs[path]
        }
        return url ?? URL(string: "https://example.invalid/\(path)")!
    }

    // MARK: 내부

    private func respond(kind: Kind, name: String, params: [String: JSONValue], body: JSONValue? = nil,
                         requireRegistered: Bool) async throws -> JSONValue {
        let (response, delay) = state.withValue { state -> (Response?, UInt64) in
            state.calls.append(Call(kind: kind, name: name, params: params, body: body))
            return (state.responses[name], state.delayNanoseconds)
        }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        switch response {
        case .handler(let handler): return try handler(params)
        case .error(let error): throw error
        case nil:
            if requireRegistered { throw BackendError(code: "fake_unregistered:\(name)") }
            return .null
        }
    }

    private static func decode<T: Decodable>(_ json: JSONValue) throws -> T {
        let data = try JSONEncoder().encode(json)
        return try PonduJSON.makeDecoder().decode(T.self, from: data)
    }
}

/// 가짜 로그인. 코드는 `validCode`일 때만 통과한다.
public final class FakeAuthService: AuthService, @unchecked Sendable {
    private struct State {
        var userID: UUID?
        var sentTo: [String] = []
        var verified: [(String, String)] = []
        var sendError: BackendError?
        var signOutCount = 0
        var continuations: [AsyncStream<UUID?>.Continuation] = []
    }

    public let validCode: String
    private let state: Locked<State>

    public init(userID: UUID? = nil, validCode: String = "123456") {
        self.validCode = validCode
        self.state = Locked(State(userID: userID))
    }

    public var currentUserID: UUID? { state.withValue { $0.userID } }
    public var sentTo: [String] { state.withValue { $0.sentTo } }
    public var signOutCount: Int { state.withValue { $0.signOutCount } }
    public var verifyAttempts: Int { state.withValue { $0.verified.count } }

    public func setSendError(code: String?) {
        state.withValue { $0.sendError = code.map { BackendError(code: $0) } }
    }

    public func sendCode(email: String) async throws {
        try state.withValue { state in
            state.sentTo.append(email)
            if let error = state.sendError { throw error }
        }
    }

    public func verify(email: String, code: String) async throws {
        let (ok, continuations, id) = state.withValue { state -> (Bool, [AsyncStream<UUID?>.Continuation], UUID) in
            state.verified.append((email, code))
            let ok = code == validCode
            let id = UUID()
            if ok { state.userID = id }
            return (ok, state.continuations, id)
        }
        guard ok else { throw BackendError(code: "otp_invalid") }
        continuations.forEach { $0.yield(id) }
    }

    public func signOut() async throws {
        let continuations = state.withValue { state -> [AsyncStream<UUID?>.Continuation] in
            state.signOutCount += 1
            state.userID = nil
            return state.continuations
        }
        continuations.forEach { $0.yield(nil) }
    }

    public func userChanges() -> AsyncStream<UUID?> {
        AsyncStream { continuation in
            state.withValue { $0.continuations.append(continuation) }
        }
    }
}

/// 가짜 세션 컨트롤러. `지금 시작`·`같이 하기`가 올바른 요청으로 불렸는지 확인할 때 쓴다.
@MainActor
public final class FakeSessionController: SessionControlling {
    public private(set) var presented: [StartSessionRequest] = []
    public var liveSession: SessionDTO?

    public init(liveSession: SessionDTO? = nil) {
        self.liveSession = liveSession
    }

    public func presentStart(_ request: StartSessionRequest) {
        presented.append(request)
    }
}
