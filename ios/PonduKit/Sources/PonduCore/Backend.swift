import Foundation

/// 서버 접근의 유일한 통로. 화면과 모델은 SDK를 직접 부르지 않고 이것만 안다.
public protocol Backend: Sendable {
    var currentUserID: UUID? { get }
    /// 서버 함수 호출. params의 키는 p_ 접두사를 포함한 서버 인자 이름 그대로.
    func rpc<T: Decodable>(_ name: String, _ params: [String: JSONValue]) async throws -> T
    func rpcVoid(_ name: String, _ params: [String: JSONValue]) async throws
    func call<T: Decodable>(function: String, body: JSONValue) async throws -> T
    func stream(function: String, body: JSONValue) -> AsyncThrowingStream<ServerEvent, Error>
    func upload(path: String, fileURL: URL, contentType: String) async throws   // 백그라운드 전송
    func signedURL(path: String) async throws -> URL
}

extension Backend {
    /// 인자 없는 서버 함수.
    public func rpc<T: Decodable>(_ name: String) async throws -> T {
        try await rpc(name, [:])
    }
}

/// 서버 함수(스트리밍)가 보낸 이벤트 한 건. `data`는 이벤트의 data 줄을 이어 붙인 본문(JSON).
public struct ServerEvent: Sendable {
    public let name: String
    public let data: Data

    public init(name: String = "message", data: Data = Data()) {
        self.name = name
        self.data = data
    }

    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try PonduJSON.makeDecoder().decode(T.self, from: data)
    }
}

/// 서버 오류. `code`는 계약 4절의 코드, 또는 `network`, `timeout`, `unknown`,
/// 인증 단계의 `otp_invalid`, `otp_expired`.
public struct BackendError: Error, Equatable, Sendable {
    public let code: String

    public init(code: String = "unknown") {
        self.code = code
    }

    public static let network = BackendError(code: "network")
    public static let timeout = BackendError(code: "timeout")
    public static let unknown = BackendError(code: "unknown")
    public static let notAuthenticated = BackendError(code: "not_authenticated")

    /// 계약 4절의 코드 전체.
    public static let contractCodes: [String] = [
        "not_authenticated", "not_found", "forbidden", "invalid_input", "email_domain_not_allowed",
        "handle_taken", "handle_invalid", "profile_required", "session_already_active", "session_not_active",
        "visibility_not_available", "join_not_allowed", "already_friends", "request_not_found", "blocked",
        "crew_full", "invite_invalid", "proposal_not_found", "proposal_already_applied", "quota_exceeded",
        "assistant_unavailable", "rate_limited",
    ]

    /// 연결이 없어서 생긴 오류인가(다시 시도 버튼을 보여 줄 만한 것).
    public var isConnectivity: Bool { code == "network" || code == "timeout" }

    /// 화면에 보여 줄 한국어 문구.
    public var userMessage: String {
        switch code {
        case "network": return "인터넷 연결을 확인해 주세요."
        case "timeout": return "응답이 늦어요. 잠시 뒤에 다시 시도해 주세요."
        case "not_authenticated": return "로그인이 필요해요."
        case "not_found": return "찾을 수 없어요."
        case "forbidden": return "할 수 없는 동작이에요."
        case "invalid_input": return "입력을 확인해 주세요."
        case "email_domain_not_allowed": return "고려대학교 메일(@korea.ac.kr)만 가입할 수 있어요."
        case "handle_taken": return "이미 쓰고 있는 아이디예요."
        case "handle_invalid": return "아이디는 영문 소문자, 숫자, 밑줄로 3~20자여야 해요."
        case "profile_required": return "프로필을 먼저 만들어 주세요."
        case "session_already_active": return "이미 진행 중인 세션이 있어요."
        case "session_not_active": return "진행 중인 세션이 아니에요."
        case "visibility_not_available": return "아직 쓸 수 없는 공개 범위예요."
        case "join_not_allowed": return "이 세션에는 같이 할 수 없어요."
        case "already_friends": return "이미 친구예요."
        case "request_not_found": return "친구 요청을 찾을 수 없어요."
        case "blocked": return "할 수 없는 동작이에요."
        case "crew_full": return "크루 인원이 가득 찼어요."
        case "invite_invalid": return "초대 코드를 확인해 주세요."
        case "proposal_not_found": return "제안을 찾을 수 없어요."
        case "proposal_already_applied": return "이미 적용한 제안이에요."
        case "quota_exceeded": return "오늘 쓸 수 있는 횟수를 모두 썼어요."
        case "assistant_unavailable": return "비서를 지금은 쓸 수 없어요. 직접 입력해 주세요."
        case "rate_limited": return "요청이 너무 잦아요. 잠시 뒤에 다시 시도해 주세요."
        case "otp_invalid": return "코드가 맞지 않아요. 다시 입력해 주세요."
        case "otp_expired": return "코드가 만료됐어요. 다시 받아 주세요."
        default: return "문제가 생겼어요. 다시 시도해 주세요."
        }
    }
}

extension Error {
    /// 어떤 오류든 화면용 한국어 문구로.
    public var ponduMessage: String {
        if let error = self as? BackendError { return error.userMessage }
        return BackendError.unknown.userMessage
    }
}

// MARK: - 로그인

/// 로그인·로그아웃. Backend에는 없는 계약 밖 부분이라 따로 둔다(SupabaseBackend가 둘 다 구현).
public protocol AuthService: Sendable {
    var currentUserID: UUID? { get }
    /// 6자리 코드를 메일로 보낸다.
    func sendCode(email: String) async throws
    /// 메일로 받은 6자리 코드를 확인하고 로그인한다. 실패: `otp_invalid`, `otp_expired`.
    func verify(email: String, code: String) async throws
    func signOut() async throws
    /// 로그인(`id`)·로그아웃(`nil`)이 일어날 때마다 내보낸다. 시작할 때의 현재 상태는 내보내지 않는다.
    func userChanges() -> AsyncStream<UUID?>
}

/// 로그인 기능이 연결되지 않은 자리(테스트·미리보기)에서 쓰는 기본값.
public struct UnavailableAuthService: AuthService {
    public init() {}
    public var currentUserID: UUID? { nil }
    public func sendCode(email: String) async throws { throw BackendError.unknown }
    public func verify(email: String, code: String) async throws { throw BackendError.unknown }
    public func signOut() async throws {}
    public func userChanges() -> AsyncStream<UUID?> { AsyncStream { $0.finish() } }
}

// MARK: - 세션 연결

/// 시작 화면을 부르는 요청.
public struct StartSessionRequest {
    public var category: ActivityCategory?
    public var threadID: UUID?
    public var todoID: UUID?
    public var planBlockID: UUID?
    public var title: String?
    public var joinedSessionID: UUID?
    public var joinedWithName: String?

    public init(category: ActivityCategory? = nil, threadID: UUID? = nil, todoID: UUID? = nil, planBlockID: UUID? = nil,
                title: String? = nil, joinedSessionID: UUID? = nil, joinedWithName: String? = nil) {
        self.category = category
        self.threadID = threadID
        self.todoID = todoID
        self.planBlockID = planBlockID
        self.title = title
        self.joinedSessionID = joinedSessionID
        self.joinedWithName = joinedWithName
    }
}

public protocol SessionControlling: AnyObject {
    /// 시작 화면을 띄운다. 오늘 탭의 `지금 시작`, 함께 탭의 `같이 하기`가 부른다.
    @MainActor func presentStart(_ request: StartSessionRequest)
    @MainActor var liveSession: SessionDTO? { get }
}

/// 앱이 각 기능 화면에 건네는 의존 묶음.
public struct AppDependencies {
    public let backend: Backend
    public let sessions: SessionControlling      // G가 구현, F가 주입
    public let now: @Sendable () -> Date
    /// 계약 밖 추가분: 가입·프로필 화면이 쓴다.
    public let auth: AuthService
    /// 계약 밖 추가분: 내 프로필 기기 캐시. 프로필을 고치면 여기에도 저장한다.
    public let profiles: ProfileCache

    public init(backend: Backend,
                sessions: SessionControlling,
                now: @escaping @Sendable () -> Date = { Date() },
                auth: AuthService = UnavailableAuthService(),
                profiles: ProfileCache = ProfileCache(inMemory: true)) {
        self.backend = backend
        self.sessions = sessions
        self.now = now
        self.auth = auth
        self.profiles = profiles
    }
}

extension Notification.Name {
    /// 로그아웃이 끝났을 때 보낸다. 각 기능은 자기 기기 캐시와 예약 알림을 지운다.
    public static let ponduDidSignOut = Notification.Name("kr.pondu.didSignOut")
}
