import Foundation
import PonduCore

// FeatureTogether 안에서만 쓰는 작은 부품. PonduCore에 없는 응답 모양과 공용 도우미.

extension CrewMemberDTO {
    var isOwner: Bool { role == "owner" }
}

/// 한마디 목록에 그리는 값. CommentDTO를 그대로 쓰지 않는 이유는
/// 보내는 중인 한마디를 임시로 보여 줘야 해서다.
struct DisplayComment: Identifiable, Equatable {
    let id: UUID
    let authorName: String
    let body: String
    let createdAt: Date
    var isPending: Bool
}

enum TogetherParam {
    static func id(_ id: UUID) -> JSONValue { .string(id.uuidString.lowercased()) }
    static func optionalString(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }
    static func optionalID(_ value: UUID?) -> JSONValue { value.map { id($0) } ?? .null }
}

enum TogetherText {
    /// 서버 오류 코드(계약 4절)와 네트워크 오류를 사용자 문구로 바꾼다.
    static func message(for error: Error) -> String {
        let code = (error as? BackendError)?.code ?? "unknown"
        switch code {
        case "blocked": return "차단 관계라 할 수 없어요."
        case "already_friends": return "이미 친구예요."
        case "request_not_found": return "요청을 찾지 못했어요. 새로 고쳐 주세요."
        case "crew_full": return "크루 인원이 가득 찼어요."
        case "invite_invalid": return "초대 코드를 다시 확인해 주세요."
        case "join_not_allowed": return "지금은 같이 할 수 없는 기록이에요."
        case "forbidden": return "할 수 없는 동작이에요."
        case "not_found": return "찾을 수 없어요. 이미 사라졌을 수 있어요."
        case "invalid_input": return "입력을 확인해 주세요."
        case "network", "timeout": return "연결이 불안정해요. 잠시 후 다시 시도해 주세요."
        case "rate_limited": return "너무 자주 눌렀어요. 잠시 후 다시 시도해 주세요."
        default: return "잠시 후 다시 시도해 주세요."
        }
    }

    /// 기록 방식 표시. 방식만 말하고 "인증"이라는 말은 쓰지 않는다(PRD 5·6절).
    static func methodLabels(captureMode: CaptureMode, endCorrected: Bool, offlineStarted: Bool) -> [String] {
        var labels: [String] = []
        switch captureMode {
        case .inAppPhoto: labels.append("앱 촬영 첨부")
        case .noPhoto: labels.append("사진 없는 기록")
        }
        if endCorrected { labels.append("나중에 정정함") }
        if offlineStarted { labels.append("오프라인 시작") }
        return labels
    }

    static func minutesText(seconds: Int, isLive: Bool) -> String {
        let minutes = max(0, seconds / 60)
        let body: String
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            body = m == 0 ? "\(h)시간" : "\(h)시간 \(m)분"
        } else {
            body = "\(minutes)분"
        }
        // "세션 시작 후 N분"은 쓰고 "N분 집중 인증"은 쓰지 않는다.
        return isLive ? "세션 시작 후 \(body)" : "\(body) 기록"
    }
}
