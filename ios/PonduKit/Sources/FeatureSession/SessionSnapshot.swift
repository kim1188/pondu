import Foundation
import PonduCore

/// 서버 Session JSON에서 이 타깃이 쓰는 필드만 읽은 값.
/// PonduCore의 SessionDTO 필드 이름·타입에 기대지 않으려고 따로 둔다(분야·상태는 서버 문자열 그대로).
/// 디코더가 snake_case를 camelCase로 바꿔 준다는 계약 5절을 전제로 한다.
struct SessionSnapshot: Decodable, Equatable {
    var id: UUID
    var primaryCategory: String
    var startedAt: Date
    var pausedAt: Date?
    var pausedSeconds: Double
    var durationSeconds: Double
    var status: String
    var captureMode: String
    var shareTitle: String?
    var visibility: String
    var endCorrected: Bool
    var offlineStartedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, primaryCategory, startedAt, pausedAt, pausedSeconds, durationSeconds
        case status, captureMode, shareTitle, visibility, endCorrected, offlineStartedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        primaryCategory = try c.decode(String.self, forKey: .primaryCategory)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        pausedAt = try c.decodeIfPresent(Date.self, forKey: .pausedAt)
        pausedSeconds = try c.decodeIfPresent(Double.self, forKey: .pausedSeconds) ?? 0
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        status = try c.decode(String.self, forKey: .status)
        captureMode = try c.decodeIfPresent(String.self, forKey: .captureMode) ?? "no_photo"
        shareTitle = try c.decodeIfPresent(String.self, forKey: .shareTitle)
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility) ?? "private"
        endCorrected = try c.decodeIfPresent(Bool.self, forKey: .endCorrected) ?? false
        offlineStartedAt = try c.decodeIfPresent(Date.self, forKey: .offlineStartedAt)
    }

    var phase: SessionPhase { SessionPhase(rawValue: status) ?? .live }
}

/// 같은 JSON을 내 스냅샷과 PonduCore의 SessionDTO로 한 번에 읽는다.
/// 로직은 스냅샷으로 하고, `SessionControlling.liveSession`에는 dto를 준다.
struct SessionPair: Decodable {
    let snapshot: SessionSnapshot
    let dto: SessionDTO

    init(from decoder: Decoder) throws {
        snapshot = try SessionSnapshot(from: decoder)
        dto = try SessionDTO(from: decoder)
    }
}

enum SessionPhase: String {
    case live
    case paused
    case ended
    case needsConfirmation = "needs_confirmation"
}

/// 종료 화면의 결과 3택. serverValue는 session_outcome 열거형 값.
enum EndChoice: String, CaseIterable, Identifiable {
    case done, more, stop
    var id: String { rawValue }
    var serverValue: String { rawValue }
    var title: String {
        switch self {
        case .done: return "끝냈어요"
        case .more: return "더 해야 해요"
        case .stop: return "오늘은 여기까지"
        }
    }
}

/// 공개 대상 3택(나만, 친구, 크루). 서버 visibility 값과 대응.
enum ShareTarget: String, CaseIterable, Identifiable {
    case `private`, friends, crew
    var id: String { rawValue }
    var title: String {
        switch self {
        case .private: return "나만"
        case .friends: return "친구"
        case .crew: return "크루"
        }
    }
}

/// 분야와 종료 확인 한도(시간). CONTRACT 3절 B sessions.
enum SessionRules {
    static let categories: [String] = ["study", "coding", "exercise", "project", "venture_research_intern", "parttime"]
    static func limitHours(for category: String) -> Double {
        switch category {
        case "study", "coding", "project": return 4
        case "exercise": return 3
        case "venture_research_intern", "parttime": return 10
        default: return 4
        }
    }
    /// 서버는 offline_started_at을 과거 12시간 이내만 받는다. 여유 1분.
    static let offlineMaxAge: TimeInterval = 12 * 3600 - 60
}

enum ErrorText {
    static func message(for code: String) -> String {
        switch code {
        case "session_already_active": return "이미 진행 중인 세션이 있어요."
        case "session_not_active": return "이미 끝났거나 진행 중이 아닌 세션이에요."
        case "visibility_not_available": return "이 공개 대상은 아직 쓸 수 없어요."
        case "join_not_allowed": return "같이 하기를 시작할 수 없어요. 상대가 아직 하는 중인지 확인해 주세요."
        case "not_authenticated": return "다시 로그인해 주세요."
        case "invalid_input": return "입력한 값을 서버가 받지 못했어요. 다시 확인해 주세요."
        case "network", "timeout": return "연결이 불안정해요. 잠시 뒤 다시 시도해 주세요."
        default: return "문제가 생겼어요. 다시 시도해 주세요."
        }
    }
}
