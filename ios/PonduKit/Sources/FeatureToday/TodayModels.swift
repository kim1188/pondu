import Foundation
import PonduCore

// FeatureToday 안에서만 쓰는 값 모양. 서버 JSON(3절)을 그대로 받되 PonduCore의 DTO에는 기대지 않는다.
// (기기 저장과 테스트에서 Codable로 다뤄야 해서 따로 둔다. 시작 화면으로 넘길 때만 PonduCore 타입을 쓴다.)

enum TodayISO {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ s: String) -> Date? { plain.date(from: s) ?? fractional.date(from: s) }
    static func string(_ d: Date) -> String { plain.string(from: d) }
}

enum TodayCoding {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = TodayISO.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "날짜 형식이 아님: \(s)")
            }
            return date
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(TodayISO.string(date))
        }
        return e
    }()
}

struct TodayTodo: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var threadId: UUID?
    var title: String
    var dueAt: Date?
    var dueHasTime: Bool
    var estimateMin: Int?
    var status: String          // open, in_progress, done, dropped
    var completedAt: Date?
    var completionSource: String?
    var source: String?
    var sourceRef: String?

    init(id: UUID = UUID(), threadId: UUID? = nil, title: String, dueAt: Date? = nil, dueHasTime: Bool = false,
         estimateMin: Int? = nil, status: String = "open", completedAt: Date? = nil,
         completionSource: String? = nil, source: String? = nil, sourceRef: String? = nil) {
        self.id = id; self.threadId = threadId; self.title = title; self.dueAt = dueAt
        self.dueHasTime = dueHasTime; self.estimateMin = estimateMin; self.status = status
        self.completedAt = completedAt; self.completionSource = completionSource
        self.source = source; self.sourceRef = sourceRef
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        threadId = try c.decodeIfPresent(UUID.self, forKey: .threadId)
        title = try c.decode(String.self, forKey: .title)
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        dueHasTime = try c.decodeIfPresent(Bool.self, forKey: .dueHasTime) ?? false
        estimateMin = try c.decodeIfPresent(Int.self, forKey: .estimateMin)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        completionSource = try c.decodeIfPresent(String.self, forKey: .completionSource)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        sourceRef = try c.decodeIfPresent(String.self, forKey: .sourceRef)
    }

    var isDone: Bool { status == "done" }
    var isOpen: Bool { status == "open" || status == "in_progress" }
}

struct TodayBlock: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var todoId: UUID?
    var threadId: UUID?
    var startAt: Date
    var endAt: Date
    var locked: Bool
    var origin: String          // user, assistant
    var status: String          // planned, started, missed, moved, cancelled

    init(id: UUID = UUID(), todoId: UUID? = nil, threadId: UUID? = nil, startAt: Date, endAt: Date,
         locked: Bool = false, origin: String = "user", status: String = "planned") {
        self.id = id; self.todoId = todoId; self.threadId = threadId; self.startAt = startAt
        self.endAt = endAt; self.locked = locked; self.origin = origin; self.status = status
    }

    var isPlanned: Bool { status == "planned" }
    var interval: DateInterval { DateInterval(start: startAt, end: max(endAt, startAt)) }
}

struct TodayThread: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var shareTitle: String?
    var primaryCategory: String?
    var defaultVisibility: String?
    var archivedAt: Date?
}

struct TodayLiveSession: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var threadId: UUID?
    var todoId: UUID?
    var status: String
    var primaryCategory: String?
    var startedAt: Date
    var pausedSeconds: Int?
    var shareTitle: String?
}

/// `get_today` 응답 그대로.
struct TodayWire: Codable, Sendable {
    var todos: [TodayTodo]
    var blocks: [TodayBlock]
    var threads: [TodayThread]
    var liveSession: TodayLiveSession?
    var estimateFactors: [String: Double]

    init(todos: [TodayTodo], blocks: [TodayBlock], threads: [TodayThread],
         liveSession: TodayLiveSession?, estimateFactors: [String: Double]) {
        self.todos = todos; self.blocks = blocks; self.threads = threads
        self.liveSession = liveSession; self.estimateFactors = estimateFactors
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        todos = try c.decodeIfPresent([TodayTodo].self, forKey: .todos) ?? []
        blocks = try c.decodeIfPresent([TodayBlock].self, forKey: .blocks) ?? []
        threads = try c.decodeIfPresent([TodayThread].self, forKey: .threads) ?? []
        liveSession = try c.decodeIfPresent(TodayLiveSession.self, forKey: .liveSession)
        estimateFactors = try c.decodeIfPresent([String: Double].self, forKey: .estimateFactors) ?? [:]
    }
}

/// 기기에 저장해 두고 먼저 그리는 값.
struct TodaySnapshot: Codable, Sendable {
    var day: String             // yyyy-MM-dd (기기 시간대 기준)
    var todos: [TodayTodo]
    var blocks: [TodayBlock]
    var threads: [TodayThread]
    var liveSession: TodayLiveSession?
    var estimateFactors: [String: Double]
    var fetchedAt: Date

    init(day: String, wire: TodayWire, fetchedAt: Date) {
        self.day = day; self.todos = wire.todos; self.blocks = wire.blocks; self.threads = wire.threads
        self.liveSession = wire.liveSession; self.estimateFactors = wire.estimateFactors; self.fetchedAt = fetchedAt
    }

    func todo(_ id: UUID?) -> TodayTodo? { id.flatMap { i in todos.first { $0.id == i } } }
    func thread(_ id: UUID?) -> TodayThread? { id.flatMap { i in threads.first { $0.id == i } } }
}

// MARK: - JSONValue 도우미

extension JSONValue {
    static func uuid(_ id: UUID?) -> JSONValue { id.map { .string($0.uuidString.lowercased()) } ?? .null }
    static func date(_ d: Date?) -> JSONValue { d.map { .string(TodayISO.string($0)) } ?? .null }
    static func int(_ i: Int?) -> JSONValue { i.map { .number(Double($0)) } ?? .null }
    static func text(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
}
