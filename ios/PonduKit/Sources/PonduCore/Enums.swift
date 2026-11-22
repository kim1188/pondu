import Foundation

/// 활동 분야. 원시값은 서버 enum `category` 그대로.
public enum Category: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case study
    case coding
    case exercise
    case project
    case ventureResearchIntern = "venture_research_intern"
    case parttime

    public var id: String { rawValue }
}

public enum Visibility: String, Codable, CaseIterable, Sendable, Hashable {
    case `private`
    case friends
    case crew
    /// 꺼 둔 단계. `start_session`이 `visibility_not_available`로 거절한다.
    case department
    case school

    public var displayName: String {
        switch self {
        case .private: return "나만"
        case .friends: return "친구"
        case .crew: return "크루"
        case .department: return "학과"
        case .school: return "학교"
        }
    }

    /// 지금 고를 수 있는 단계.
    public static let selectable: [Visibility] = [.private, .friends, .crew]
}

public enum SessionStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case live
    case paused
    case ended
    case needsConfirmation = "needs_confirmation"
}

public enum SessionOutcome: String, Codable, CaseIterable, Sendable, Hashable {
    case done
    case more
    case stop

    public var displayName: String {
        switch self {
        case .done: return "다 했어요"
        case .more: return "더 해야 해요"
        case .stop: return "여기까지만 할래요"
        }
    }
}

public enum CaptureMode: String, Codable, CaseIterable, Sendable, Hashable {
    case inAppPhoto = "in_app_photo"
    case noPhoto = "no_photo"

    /// 기록 방식 표시. 등급이 아니라 방식만 말한다(PRD 5·6절).
    public var displayName: String {
        switch self {
        case .inAppPhoto: return "앱 촬영 첨부"
        case .noPhoto: return "사진 없는 기록"
        }
    }
}

public enum TodoStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case open
    case inProgress = "in_progress"
    case done
    case dropped
}

public enum BlockStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case planned, started, missed, moved, cancelled
}

public enum BlockOrigin: String, Codable, CaseIterable, Sendable, Hashable {
    case user, assistant
}

/// 기록 방식 표시 문구를 한 곳에서 만든다. "인증"이라는 말은 쓰지 않는다.
public enum RecordBadge {
    public static let corrected = "나중에 정정함"
    public static let offlineStart = "오프라인 시작"

    /// 카드에 붙일 표시를 순서대로 돌려준다: 기록 방식, 정정, 오프라인 시작.
    public static func labels(captureMode: CaptureMode, endCorrected: Bool, offlineStarted: Bool) -> [String] {
        var result = [captureMode.displayName]
        if endCorrected { result.append(corrected) }
        if offlineStarted { result.append(offlineStart) }
        return result
    }
}

/// `{items, next_cursor}` 모양의 목록 한 쪽.
public struct Page<T: Decodable & Sendable>: Decodable, Sendable {
    public var items: [T]
    public var nextCursor: String?

    public init(items: [T], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

extension Page: Encodable where T: Encodable {}
extension Page: Equatable where T: Equatable {}
extension Page: Hashable where T: Hashable {}

/// 목록 화면 한 쪽의 크기. 계약: 20개씩.
public enum PageSize {
    public static let standard = 20
}
