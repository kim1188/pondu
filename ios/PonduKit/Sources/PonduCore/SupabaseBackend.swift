import Foundation
import Supabase

/// 프로젝트 주소와 공개용 키. 관리자 키는 앱에 넣지 않는다.
public struct BackendConfig: Sendable {
    public var url: URL
    public var anonKey: String
    public var photoBucket: String

    public init(url: URL, anonKey: String, photoBucket: String = "session-photos") {
        self.url = url
        self.anonKey = anonKey
        self.photoBucket = photoBucket
    }
}

/// supabase-swift를 감싼 `Backend` 실제 구현. 화면은 SDK를 직접 부르지 않는다.
///
/// - 서버 함수(rpc)는 SDK(`client.rpc`)로 부른다. 읽기 함수(`get_`, `list_`, `search_`, `is_`)는
///   진행 중인 같은 요청을 하나로 합치고, 연결 문제일 때만 간격을 늘려 2회 다시 시도한다.
///   쓰기 함수는 다시 시도하지 않는다(중복 방지 키가 있는 `start_session`은 호출한 쪽이 다시 부른다).
/// - 서버 함수(Edge)·스트리밍·저장소는 URLSession으로 직접 부른다. SDK 버전에 따라 모양이 달라지는
///   부분(스트리밍, 백그라운드 전송)을 피하려는 선택이다.
/// - 일반 10초, 비서 20초, 사진 60초 시간 제한.
public final class SupabaseBackend: Backend, AuthService, @unchecked Sendable {
    public let config: BackendConfig
    private let client: SupabaseClient
    private let urlSession: URLSession
    private let flight = InFlight<String, Data>()
    private let uploader: BackgroundUploader
    private let decoder = PonduJSON.makeDecoder()

    public init(config: BackendConfig) {
        self.config = config
        self.client = SupabaseClient(supabaseURL: config.url, supabaseKey: config.anonKey)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = RequestTimeout.standard
        configuration.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: configuration)
        self.uploader = BackgroundUploader()
    }

    // MARK: Backend

    public var currentUserID: UUID? { client.auth.currentSession?.user.id }

    public func rpc<T: Decodable>(_ name: String, _ params: [String: JSONValue]) async throws -> T {
        let data = try await rpcData(name, params)
        let payload = data.isEmpty ? Data("null".utf8) : data
        do {
            return try decoder.decode(T.self, from: payload)
        } catch {
            throw BackendError.unknown
        }
    }

    public func rpcVoid(_ name: String, _ params: [String: JSONValue]) async throws {
        _ = try await rpcData(name, params)
    }

    public func call<T: Decodable>(function: String, body: JSONValue) async throws -> T {
        do {
            let data: Data = try await withTimeout(RequestTimeout.assistant) { [self] in
                let request = try await functionRequest(function, body: body, timeout: RequestTimeout.assistant)
                let (data, response) = try await urlSession.data(for: request)
                try ErrorMapping.check(response, body: data)
                return data
            }
            return try decoder.decode(T.self, from: data)
        } catch let error as DecodingError {
            _ = error
            throw BackendError.unknown
        } catch {
            throw ErrorMapping.map(error)
        }
    }

    public func stream(function: String, body: JSONValue) -> AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    // 비서는 요청당 20초 안에 끝나야 한다.
                    try await withTimeout(RequestTimeout.assistant) { [self] in
                        let request = try await functionRequest(function, body: body, timeout: RequestTimeout.assistant,
                                                                accept: "text/event-stream")
                        let (bytes, response) = try await urlSession.bytes(for: request)
                        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                            var errorBody = Data()
                            for try await byte in bytes { errorBody.append(byte); if errorBody.count > 4096 { break } }
                            try ErrorMapping.check(response, body: errorBody)
                        }
                        try await Self.pump(bytes, into: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ErrorMapping.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func upload(path: String, fileURL: URL, contentType: String) async throws {
        do {
            let token = try await accessToken()
            guard let url = storageURL("object/\(config.photoBucket)", path: path) else { throw BackendError.unknown }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = RequestTimeout.photo
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue("true", forHTTPHeaderField: "x-upsert")   // 같은 경로 덮어쓰기: 다시 올려도 안전
            request.setValue("max-age=31536000", forHTTPHeaderField: "Cache-Control")
            try await uploader.upload(request: request, fileURL: fileURL)
        } catch {
            throw ErrorMapping.map(error)
        }
    }

    public func signedURL(path: String) async throws -> URL {
        do {
            return try await withTimeout(RequestTimeout.standard) { [self] in
                let token = try await accessToken()
                guard let url = storageURL("object/sign/\(config.photoBucket)", path: path) else { throw BackendError.unknown }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = RequestTimeout.standard
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(["expiresIn": 3600])
                let (data, response) = try await urlSession.data(for: request)
                try ErrorMapping.check(response, body: data)
                let json = try JSONDecoder().decode(JSONValue.self, from: data)
                guard let signed = json["signedURL"]?.stringValue ?? json["signedUrl"]?.stringValue else {
                    throw BackendError.unknown
                }
                return try resolveSignedURL(signed)
            }
        } catch {
            throw ErrorMapping.map(error)
        }
    }

    // MARK: AuthService

    public func sendCode(email: String) async throws {
        do {
            try await withTimeout(RequestTimeout.standard) { [client] in
                try await client.auth.signInWithOTP(email: email, shouldCreateUser: true)
            }
        } catch {
            throw ErrorMapping.mapAuth(error)
        }
    }

    public func verify(email: String, code: String) async throws {
        do {
            try await withTimeout(RequestTimeout.standard) { [client] in
                _ = try await client.auth.verifyOTP(email: email, token: code, type: .email)
            }
        } catch {
            throw ErrorMapping.mapAuth(error)
        }
    }

    public func signOut() async throws {
        do {
            try await client.auth.signOut(scope: .local)
        } catch {
            throw ErrorMapping.map(error)
        }
    }

    public func userChanges() -> AsyncStream<UUID?> {
        let client = self.client
        return AsyncStream { continuation in
            let task = Task {
                for await change in client.auth.authStateChanges {
                    switch change.event {
                    case .signedIn: continuation.yield(change.session?.user.id)
                    case .signedOut: continuation.yield(nil)
                    default: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: 내부

    private static func isRead(_ name: String) -> Bool {
        ["get_", "list_", "search_", "is_"].contains { name.hasPrefix($0) }
    }

    private static func flightKey(_ name: String, _ params: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(params)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return name + "|" + body
    }

    private func rpcData(_ name: String, _ params: [String: JSONValue]) async throws -> Data {
        let client = self.client
        let operation: @Sendable () async throws -> Data = {
            try await withTimeout(RequestTimeout.standard) {
                let response: PostgrestResponse<Void> = try await client.rpc(name, params: params).execute()
                return response.data
            }
        }
        do {
            if Self.isRead(name) {
                return try await flight.run(key: Self.flightKey(name, params)) {
                    try await Self.retrying(operation)
                }
            }
            return try await operation()
        } catch {
            throw ErrorMapping.map(error)
        }
    }

    /// 연결 문제일 때만 간격을 늘려 2회까지 다시 시도한다.
    private static func retrying<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                attempt += 1
                let mapped = ErrorMapping.map(error)
                guard attempt <= 2, !Task.isCancelled, let backendError = mapped as? BackendError, backendError.isConnectivity else {
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 600_000_000)
            }
        }
    }

    private func accessToken() async throws -> String {
        do {
            return try await client.auth.session.accessToken
        } catch {
            // 저장된 로그인이 없으면 로그인 필요, 있는데 갱신이 안 되면 연결 문제로 본다.
            if client.auth.currentSession == nil { throw BackendError.notAuthenticated }
            throw ErrorMapping.map(error)
        }
    }

    private func functionRequest(_ function: String, body: JSONValue, timeout: TimeInterval,
                                 accept: String = "application/json") async throws -> URLRequest {
        let token = try await accessToken()
        let url = config.url.appendingPathComponent("functions/v1/\(function)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// `{프로젝트}/storage/v1/{prefix}/{경로}`. 경로의 각 조각을 따로 인코딩한다.
    private func storageURL(_ prefix: String, path: String) -> URL? {
        let encoded = path.split(separator: "/", omittingEmptySubsequences: true).map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let base = config.url.absoluteString.hasSuffix("/") ? String(config.url.absoluteString.dropLast()) : config.url.absoluteString
        return URL(string: "\(base)/storage/v1/\(prefix)/\(encoded)")
    }

    private func resolveSignedURL(_ signed: String) throws -> URL {
        if signed.hasPrefix("http"), let url = URL(string: signed) { return url }
        let base = config.url.absoluteString.hasSuffix("/") ? String(config.url.absoluteString.dropLast()) : config.url.absoluteString
        let prefix = signed.hasPrefix("/storage/v1") ? "" : "/storage/v1"
        let separator = signed.hasPrefix("/") ? "" : "/"
        guard let url = URL(string: base + prefix + separator + signed) else { throw BackendError.unknown }
        return url
    }

    /// 이벤트 스트림을 읽어 이벤트로 나눈다. `AsyncBytes.lines`는 빈 줄을 건너뛰어서(이벤트 끝 표시) 직접 나눈다.
    private static func pump(_ bytes: URLSession.AsyncBytes,
                             into continuation: AsyncThrowingStream<ServerEvent, Error>.Continuation) async throws {
        var line = [UInt8]()
        var eventName = "message"
        var dataLines = [String]()

        func dispatch() {
            if !dataLines.isEmpty {
                continuation.yield(ServerEvent(name: eventName, data: Data(dataLines.joined(separator: "\n").utf8)))
            }
            eventName = "message"
            dataLines = []
        }

        func handle(_ raw: [UInt8]) {
            var text = String(decoding: raw, as: UTF8.self)
            if text.hasSuffix("\r") { text.removeLast() }
            if text.isEmpty { dispatch(); return }
            if text.hasPrefix(":") { return }
            let name: String
            var value: String
            if let colon = text.firstIndex(of: ":") {
                name = String(text[..<colon])
                value = String(text[text.index(after: colon)...])
                if value.hasPrefix(" ") { value.removeFirst() }
            } else {
                name = text
                value = ""
            }
            switch name {
            case "event": eventName = value
            case "data": dataLines.append(value)
            default: break
            }
        }

        for try await byte in bytes {
            if byte == 0x0A {
                handle(line)
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        if !line.isEmpty { handle(line) }
        dispatch()
    }
}
