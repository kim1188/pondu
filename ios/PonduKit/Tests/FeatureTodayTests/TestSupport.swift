import Foundation
import XCTest
import PonduCore
@testable import FeatureToday

/// 호출 기록을 남기고, 함수 이름별로 미리 넣어 둔 JSON을 돌려주는 가짜 Backend.
final class StubBackend: Backend, @unchecked Sendable {
    struct Call { var name: String; var params: [String: JSONValue] }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var responses: [String: String] = [:]          // 함수 이름 → JSON 문자열
    var failures: [String: BackendError] = [:]
    var streamEvents: [ServerEvent] = []
    var streamError: Error?
    var lastStreamBody: JSONValue?
    var callResponses: [String: String] = [:]

    var currentUserID: UUID? { UUID(uuidString: "00000000-0000-0000-0000-000000000001") }
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    func calls(named n: String) -> [Call] { calls.filter { $0.name == n } }

    private func record(_ name: String, _ params: [String: JSONValue]) { lock.lock(); _calls.append(Call(name: name, params: params)); lock.unlock() }

    func rpc<T: Decodable>(_ name: String, _ params: [String: JSONValue]) async throws -> T {
        record(name, params)
        if let f = failures[name] { throw f }
        let json = responses[name] ?? "null"
        return try TodayCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    func rpcVoid(_ name: String, _ params: [String: JSONValue]) async throws {
        record(name, params)
        if let f = failures[name] { throw f }
    }

    func call<T: Decodable>(function: String, body: JSONValue) async throws -> T {
        record("call:" + function, ["body": body])
        if let f = failures["call:" + function] { throw f }
        return try TodayCoding.decoder.decode(T.self, from: Data((callResponses[function] ?? "null").utf8))
    }

    func stream(function: String, body: JSONValue) -> AsyncThrowingStream<ServerEvent, Error> {
        lastStreamBody = body
        let events = streamEvents, err = streamError
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            if let err { c.finish(throwing: err) } else { c.finish() }
        }
    }

    func upload(path: String, fileURL: URL, contentType: String) async throws {}
    func signedURL(path: String) async throws -> URL { URL(string: "https://example.invalid")! }
}

@MainActor
final class FakeSessions: SessionControlling {
    var requests: [StartSessionRequest] = []
    func presentStart(_ request: StartSessionRequest) { requests.append(request) }
    var liveSession: SessionDTO? { nil }
}

final class MemoryStore: TodaySnapshotStoring {
    var saved: TodaySnapshot?
    func load(day: String) -> TodaySnapshot? { saved?.day == day ? saved : nil }
    func save(_ snapshot: TodaySnapshot) { saved = snapshot }
}

final class FakeCalendar: CalendarBusyProviding, @unchecked Sendable {
    var access: CalendarAccess = .granted
    var selectedCalendarIDs: Set<String>? = ["cal"]
    var stored: [CalendarEventLite] = []
    func requestAccess() async -> CalendarAccess { access }
    func availableCalendars() -> [CalendarInfo] { [CalendarInfo(id: "cal", title: "수업", sourceTitle: "iCloud")] }
    func events(in window: DateInterval) -> [CalendarEventLite] { stored.filter { $0.start < window.end && $0.end > window.start } }
}

final class FakeNotifier: NotificationScheduling {
    var synced: [[PlannedNotification]] = []
    func requestAuthorizationIfNeeded() async -> Bool { true }
    func sync(_ plans: [PlannedNotification], covering range: DateInterval) async { synced.append(plans) }
}

final class MemoryConsent: ConsentStoring { var hasConsented = false }

enum Fixture {
    static let tz = TimeZone(identifier: "Asia/Seoul")!
    /// 2026-11-23 10:00 KST
    static let now = TodayISO.parse("2026-11-23T10:00:00+09:00")!
    static func date(_ s: String) -> Date { TodayISO.parse(s)! }

    static let todoA = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
    static let todoB = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002")!
    static let block1 = UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000001")!
    static let thread1 = UUID(uuidString: "cccccccc-0000-0000-0000-000000000001")!

    static var todayJSON: String {
        """
        {"todos":[
          {"id":"\(todoA)","thread_id":"\(thread1)","title":"DB 과제","due_at":"2026-11-24T09:00:00Z","due_has_time":true,"estimate_min":60,"status":"open","completed_at":null,"completion_source":null,"source":"manual","source_ref":null,"created_at":"2026-11-20T00:00:00Z"},
          {"id":"\(todoB)","thread_id":null,"title":"운동","due_at":null,"due_has_time":false,"estimate_min":null,"status":"open","source":"text","source_ref":"ref-dup"}
        ],
        "blocks":[{"id":"\(block1)","todo_id":"\(todoA)","thread_id":"\(thread1)","start_at":"2026-11-23T01:00:00Z","end_at":"2026-11-23T02:00:00Z","locked":false,"origin":"user","status":"planned"}],
        "threads":[{"id":"\(thread1)","title":"DB 수업","share_title":null,"primary_category":"study","default_visibility":"private","archived_at":null}],
        "live_session":null,
        "estimate_factors":{"study":1.4}}
        """
    }

    @MainActor
    static func makeModel(backend: StubBackend = StubBackend(), store: MemoryStore = MemoryStore(), calendar: FakeCalendar = FakeCalendar(),
                          notifier: FakeNotifier = FakeNotifier(), sessions: FakeSessions = FakeSessions()) -> TodayModel {
        backend.responses["get_today"] = backend.responses["get_today"] ?? todayJSON
        let n = now
        return TodayModel(backend: backend, sessions: sessions, now: { n }, timeZone: tz, store: store, calendar: calendar, notifier: notifier)
    }

    static func event(_ title: String, _ s: String, _ e: String, allDay: Bool = false, free: Bool = false) -> CalendarEventLite {
        CalendarEventLite(id: UUID().uuidString, title: title, start: date(s), end: date(e), isAllDay: allDay, isFree: free, calendarName: "수업")
    }

    static func sse(_ name: String, _ json: String) -> ServerEvent { ServerEvent(name: name, data: Data(json.utf8)) }
}
