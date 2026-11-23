import Foundation
import PonduCore

/// 화면에 올릴 목록을 고르는 순수 함수들.
enum TodayLogic {
    /// 지금 시작할 수 있는 예정 시간: 시작 `lead`초 전부터 끝나기 전까지의 `planned` 블록(끝낸 할 일 제외).
    static func startable(blocks: [TodayBlock], todos: [TodayTodo], now: Date, lead: TimeInterval = 15 * 60) -> [TodayBlock] {
        blocks.filter { b in
            guard b.isPlanned, b.startAt.addingTimeInterval(-lead) <= now, now < b.endAt else { return false }
            if let id = b.todoId, let t = todos.first(where: { $0.id == id }), !t.isOpen { return false }
            return true
        }
        .sorted { $0.startAt < $1.startAt }
    }

    /// 아직 시작 시각이 오지 않은 오늘의 예정 시간.
    static func upcoming(blocks: [TodayBlock], now: Date, lead: TimeInterval = 15 * 60) -> [TodayBlock] {
        blocks.filter { $0.isPlanned && $0.startAt.addingTimeInterval(-lead) > now }.sorted { $0.startAt < $1.startAt }
    }

    /// 남은 할 일: 열려 있는 것. 마감이 빠른 순, 마감 없는 것은 뒤에서 만든 순서를 유지한다.
    static func remaining(todos: [TodayTodo]) -> [TodayTodo] {
        let open = todos.filter(\.isOpen)
        let withDue = open.filter { $0.dueAt != nil }.sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        let without = open.filter { $0.dueAt == nil }
        return withDue + without
    }

    static func doneToday(todos: [TodayTodo]) -> [TodayTodo] { todos.filter(\.isDone) }

    /// "과제는 평소 1.4배 걸려서 85분으로 잡았어요" — 배수가 1에 가까우면(±5%) 말하지 않는다.
    static func estimateNote(categoryRaw: String?, estimateMin: Int?, factors: [String: Double]) -> String? {
        guard let raw = categoryRaw, let minutes = estimateMin, let f = factor(for: raw, in: factors), abs(f - 1.0) >= 0.05 else { return nil }
        let name = ActivityCategory(serverKey: raw)?.displayName ?? raw
        let factorText = String(format: "%.1f", f)
        return "\(name)는 평소 \(factorText)배 걸려서 \(minutes)분으로 잡았어요"
    }

    /// 분야 키를 snake_case(`venture_research_intern`)와 camelCase(`ventureResearchIntern`) 어느 쪽으로 저장했어도 찾는다.
    /// 기기에 저장한 오늘 값은 키 변환 디코더로 다시 읽어서 분야 키가 camelCase로 바뀔 수 있다(계약 보정 R7).
    static func factor(for categoryRaw: String, in factors: [String: Double]) -> Double? {
        if let exact = factors[categoryRaw] { return exact }
        guard let category = ActivityCategory(serverKey: categoryRaw) else { return nil }
        return factors.first { ActivityCategory(serverKey: $0.key) == category }?.value
    }

    static func dayKey(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func calendar(timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.locale = Locale(identifier: "ko_KR")
        return cal
    }

    /// 마감 문구. 시각이 없으면 날짜만.
    static func dueText(_ todo: TodayTodo, now: Date, timeZone: TimeZone) -> String? {
        guard let due = todo.dueAt else { return nil }
        let cal = calendar(timeZone: timeZone)
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR"); f.timeZone = timeZone
        if cal.isDate(due, inSameDayAs: now) {
            f.dateFormat = "a h:mm"
            return todo.dueHasTime ? "오늘 \(f.string(from: due)) 마감" : "오늘 마감"
        }
        f.dateFormat = todo.dueHasTime ? "M월 d일 a h:mm" : "M월 d일"
        return "\(f.string(from: due)) 마감"
    }
}

// MARK: - 기기 저장

protocol TodaySnapshotStoring: AnyObject {
    func load(day: String) -> TodaySnapshot?
    func save(_ snapshot: TodaySnapshot)
}

/// 캐시 폴더의 파일 하나. 날짜가 바뀌면 어제 값은 쓰지 않는다.
final class FileSnapshotStore: TodaySnapshotStoring {
    private let url: URL
    init(userID: UUID?) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("FeatureToday", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("today-\(userID?.uuidString.lowercased() ?? "anon").json")
    }

    func load(day: String) -> TodaySnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snap = try? TodayCoding.decoder.decode(TodaySnapshot.self, from: data), snap.day == day else { return nil }
        return snap
    }

    func save(_ snapshot: TodaySnapshot) {
        guard let data = try? TodayCoding.encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
