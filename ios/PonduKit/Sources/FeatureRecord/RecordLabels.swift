import Foundation

/// 기록 방식 표시. 방식만 말하고 등급을 매기지 않는다(PRD 5·6절).
enum RecordLabels {
    static func labels(for s: RecordSession) -> [String] {
        var out: [String] = []
        switch s.status {
        case "live": out.append("진행 중")
        case "paused": out.append("일시 정지")
        case "needs_confirmation": out.append("종료 확인 필요")
        default: break
        }
        out.append(s.captureMode == "in_app_photo" ? "앱 촬영 첨부" : "사진 없는 기록")
        if s.endCorrected { out.append("나중에 정정함") }
        if s.offlineStartedAt != nil { out.append("오프라인 시작") }
        return out
    }

    /// 37분, 1시간 5분. 관측한 시간만 말한다.
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "1분 미만" }
        if minutes < 60 { return "\(minutes)분" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)시간" : "\(h)시간 \(m)분"
    }
}
