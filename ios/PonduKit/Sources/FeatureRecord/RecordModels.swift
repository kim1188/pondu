import Foundation

/// get_record_summary 응답. 이 타깃이 쓰는 열만 읽는다(분야는 서버 문자열 그대로).
struct RecordSummary: Codable, Equatable {
    var days: [DayStat] = []
    var byCategory: [CategoryStat] = []
    var threads: [ThreadStat] = []

    struct DayStat: Codable, Equatable {
        var day: String          // yyyy-MM-dd
        var seconds: Double
        var sessionCount: Int
    }
    struct CategoryStat: Codable, Equatable, Identifiable {
        var category: String
        var seconds: Double
        var id: String { category }
    }
    struct ThreadStat: Codable, Equatable, Identifiable {
        var threadId: UUID
        var title: String
        var seconds: Double
        var lastAt: Date?
        var id: UUID { threadId }
    }
}

/// list_my_sessions의 한 줄. 목록에 쓰는 열만 읽는다.
struct RecordSession: Codable, Equatable, Identifiable {
    var id: UUID
    var threadId: UUID?
    var primaryCategory: String
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double
    var status: String
    var captureMode: String
    var shareTitle: String?
    var progressNote: String?
    var endCorrected: Bool
    var offlineStartedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, threadId, primaryCategory, startedAt, endedAt, durationSeconds, status, captureMode
        case shareTitle, progressNote, endCorrected, offlineStartedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        threadId = try c.decodeIfPresent(UUID.self, forKey: .threadId)
        primaryCategory = try c.decode(String.self, forKey: .primaryCategory)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        status = try c.decode(String.self, forKey: .status)
        captureMode = try c.decodeIfPresent(String.self, forKey: .captureMode) ?? "no_photo"
        shareTitle = try c.decodeIfPresent(String.self, forKey: .shareTitle)
        progressNote = try c.decodeIfPresent(String.self, forKey: .progressNote)
        endCorrected = try c.decodeIfPresent(Bool.self, forKey: .endCorrected) ?? false
        offlineStartedAt = try c.decodeIfPresent(Date.self, forKey: .offlineStartedAt)
    }
}

struct RecordPage: Codable, Equatable {
    var items: [RecordSession]
    var nextCursor: String?
}

/// 기기에 저장해 두었다가 먼저 그리는 값.
struct RecordSnapshot: Codable, Equatable {
    var summary: RecordSummary
    var firstPage: RecordPage
    var savedAt: Date
}
