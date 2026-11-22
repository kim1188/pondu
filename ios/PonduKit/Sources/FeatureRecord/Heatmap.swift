import Foundation

/// 잔디: 기록이 남은 날을 주 단위 칸으로. 시간이 길수록 진해지지 않고 세션 수만 3단계로 나눈다.
enum Heatmap {
    struct Cell: Equatable {
        var day: String?      // yyyy-MM-dd, 범위 밖(첫 주의 앞 칸, 오늘 뒤 칸)이면 nil
        var level: Int        // 0 기록 없음, 1~3 세션 수 1, 2, 3 이상
    }

    static let defaultWeeks = 16

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 월요일 시작. 오늘이 속한 주를 포함해 weeks주.
    static func range(today: Date, weeks: Int = defaultWeeks, calendar inCalendar: Calendar) -> (from: Date, to: Date) {
        var calendar = inCalendar
        calendar.firstWeekday = 2
        let startOfToday = calendar.startOfDay(for: today)
        let weekday = calendar.component(.weekday, from: startOfToday)      // 1=일 ... 7=토
        let sinceMonday = (weekday + 5) % 7                                  // 월=0 ... 일=6
        let thisMonday = calendar.date(byAdding: .day, value: -sinceMonday, to: startOfToday) ?? startOfToday
        let from = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: thisMonday) ?? thisMonday
        return (from, startOfToday)
    }

    /// columns[주][요일(월=0)]
    static func columns(days: [RecordSummary.DayStat], today: Date, weeks: Int = defaultWeeks, calendar inCalendar: Calendar) -> [[Cell]] {
        var calendar = inCalendar
        calendar.firstWeekday = 2
        let r = range(today: today, weeks: weeks, calendar: calendar)
        let counts = Dictionary(days.map { ($0.day, $0.sessionCount) }, uniquingKeysWith: +)
        var result: [[Cell]] = []
        for w in 0..<weeks {
            var week: [Cell] = []
            for d in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: w * 7 + d, to: r.from), date <= r.to else {
                    week.append(Cell(day: nil, level: 0)); continue
                }
                let key = dayString(date, calendar: calendar)
                let n = counts[key] ?? 0
                week.append(Cell(day: key, level: n <= 0 ? 0 : min(n, 3)))
            }
            result.append(week)
        }
        return result
    }
}
