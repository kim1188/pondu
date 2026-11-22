import Foundation
import EventKit

struct CalendarInfo: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var sourceTitle: String
}

enum CalendarAccess: Sendable { case notDetermined, granted, denied }

/// 캘린더 읽기 경계. 모델은 이 프로토콜에만 의존한다(시험에서는 가짜로 바꾼다).
protocol CalendarBusyProviding: AnyObject, Sendable {
    var access: CalendarAccess { get }
    /// 앱 시작 때 한 번만 시스템 권한 창을 띄운다. 이미 결정됐으면 현재 상태를 돌려준다.
    func requestAccess() async -> CalendarAccess
    func availableCalendars() -> [CalendarInfo]
    var selectedCalendarIDs: Set<String>? { get set }   // nil이면 아직 고르지 않음
    func events(in window: DateInterval) -> [CalendarEventLite]
}

/// EventKit 구현. 읽기만 한다: `save`, `remove`, `EKEvent` 생성은 호출하지 않는다.
final class EventKitCalendarReader: CalendarBusyProviding, @unchecked Sendable {
    private let store = EKEventStore()
    private let defaults: UserDefaults
    private let key = "pondu.today.selectedCalendars.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied     // denied, restricted, writeOnly(쓰기 전용은 읽을 수 없다)
        }
    }

    func requestAccess() async -> CalendarAccess {
        if access == .notDetermined {
            // iOS 17: 전체 접근 요청. 읽기 전용 권한은 따로 없다.
            _ = try? await store.requestFullAccessToEvents()
        }
        return access
    }

    func availableCalendars() -> [CalendarInfo] {
        guard access == .granted else { return [] }
        return store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source?.title ?? "")
        }
    }

    var selectedCalendarIDs: Set<String>? {
        get { (defaults.array(forKey: key) as? [String]).map(Set.init) }
        set {
            if let v = newValue { defaults.set(Array(v).sorted(), forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    func events(in window: DateInterval) -> [CalendarEventLite] {
        guard access == .granted, let chosen = selectedCalendarIDs, !chosen.isEmpty else { return [] }
        let calendars = store.calendars(for: .event).filter { chosen.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: calendars)
        return store.events(matching: predicate).map { e in
            CalendarEventLite(
                id: "\(e.eventIdentifier ?? UUID().uuidString)#\(Int(e.startDate.timeIntervalSince1970))",
                title: e.title ?? "일정",
                start: e.startDate, end: e.endDate,
                isAllDay: e.isAllDay,
                isFree: e.availability == .free,
                calendarName: e.calendar.title)
        }
        .sorted { $0.start < $1.start }
    }
}
