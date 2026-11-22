import Foundation
import PonduCore

/// 기기 캘린더에서 읽은 일정. 제목은 기기 안(오늘 화면 표시)에서만 쓰고 서버로 보내지 않는다.
struct CalendarEventLite: Hashable, Sendable, Identifiable {
    var id: String              // eventIdentifier + 시작 시각 (반복 일정 구분)
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var isFree: Bool            // 상태가 "한가함"인 일정
    var calendarName: String
}

/// 서버(비서)로 가는 유일한 일정 정보. 시작과 끝뿐이다.
struct BusyInterval: Hashable, Sendable, Codable {
    var start: Date
    var end: Date
}

enum BusyTime {
    /// 일정 목록에서 바쁜 시간 구간을 계산한다.
    /// - 하루 종일 일정과 "한가함" 일정은 바쁜 시간으로 보지 않는다.
    /// - `window`와 겹치는 부분만 남기고, 겹치거나 맞닿은 구간은 합친다.
    static func intervals(from events: [CalendarEventLite], within window: DateInterval) -> [BusyInterval] {
        let clipped: [BusyInterval] = events.compactMap { e in
            guard !e.isAllDay, !e.isFree, e.end > e.start else { return nil }
            let s = max(e.start, window.start)
            let t = min(e.end, window.end)
            return s < t ? BusyInterval(start: s, end: t) : nil
        }
        return merge(clipped)
    }

    static func merge(_ items: [BusyInterval]) -> [BusyInterval] {
        let sorted = items.sorted { $0.start < $1.start }
        var out: [BusyInterval] = []
        for item in sorted {
            if var last = out.last, item.start <= last.end {
                last.end = max(last.end, item.end)
                out[out.count - 1] = last
            } else {
                out.append(item)
            }
        }
        return out
    }

    /// 비서 요청에 넣는 모양. 제목은 들어가지 않는다.
    static func payload(_ busy: [BusyInterval]) -> JSONValue {
        .array(busy.map { .object(["start": .date($0.start), "end": .date($0.end)]) })
    }

    /// `range`와 겹치는 바쁜 시간.
    static func conflicts(_ range: DateInterval, with busy: [BusyInterval]) -> [BusyInterval] {
        busy.filter { $0.start < range.end && $0.end > range.start }
    }

    /// 하루(`day` 시작~다음 날 시작) 구간.
    static func dayWindow(containing date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }
}
