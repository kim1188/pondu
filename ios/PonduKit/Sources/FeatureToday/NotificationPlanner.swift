import Foundation
import UserNotifications

/// 예정 시각 로컬 알림 한 건.
struct PlannedNotification: Hashable, Sendable {
    var identifier: String
    var fireDate: Date
    var title: String
    var body: String
    var blockID: UUID
    var todoID: UUID?
}

enum NotificationPlanner {
    static let idPrefix = "pondu.block."
    /// iOS는 앱당 대기 알림 64개까지만 유지한다. 여유를 둔다.
    static let maxPending = 50

    static func identifier(for blockID: UUID) -> String { idPrefix + blockID.uuidString.lowercased() }

    /// 앞으로 올 `planned` 블록마다 시작 시각에 알림을 만든다. 끝낸 할 일의 블록은 제외한다.
    static func plan(blocks: [TodayBlock], todos: [TodayTodo], now: Date, limit: Int = maxPending) -> [PlannedNotification] {
        let todoByID = Dictionary(uniqueKeysWithValues: todos.map { ($0.id, $0) })
        let items: [PlannedNotification] = blocks.compactMap { b in
            guard b.isPlanned, b.startAt > now else { return nil }
            let todo = b.todoId.flatMap { todoByID[$0] }
            if let todo, !todo.isOpen { return nil }
            return PlannedNotification(
                identifier: identifier(for: b.id),
                fireDate: b.startAt,
                title: "지금 시작할 시간이에요",
                body: todo?.title ?? "예정한 시간이 됐어요",
                blockID: b.id, todoID: b.todoId)
        }
        return Array(items.sorted { $0.fireDate < $1.fireDate }.prefix(limit))
    }

    /// 이미 잡혀 있는 알림 중, 이번에 다시 계산한 범위 안에 있는데 더는 필요 없는 것의 식별자.
    /// 범위 밖(오늘 화면이 보지 않은 날)의 알림은 건드리지 않는다.
    static func staleIdentifiers(pending: [(id: String, fire: Date?)], keep: [PlannedNotification], covering range: DateInterval) -> [String] {
        let keepIDs = Set(keep.map(\.identifier))
        return pending.compactMap { p in
            guard p.id.hasPrefix(idPrefix) else { return nil }
            if keepIDs.contains(p.id) { return nil }
            // 시각을 알 수 없거나 범위 안이면 지운다(블록이 사라졌거나 옮겨졌다).
            if let f = p.fire, !range.contains(f) { return nil }
            return p.id
        }
    }

    /// 알림 userInfo 키. 앱 쪽 delegate가 쓴다.
    static let userInfoBlockKey = "pondu_block_id"
    static let userInfoTodoKey = "pondu_todo_id"
    static let userInfoFireKey = "pondu_fire_at"
}

protocol NotificationScheduling: AnyObject {
    func requestAuthorizationIfNeeded() async -> Bool
    func sync(_ plans: [PlannedNotification], covering range: DateInterval) async
}

final class LocalNotificationScheduler: NotificationScheduling {
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    func sync(_ plans: [PlannedNotification], covering range: DateInterval) async {
        let pending = await center.pendingNotificationRequests()
        let pairs: [(id: String, fire: Date?)] = pending.map { r in
            let fire = (r.content.userInfo[NotificationPlanner.userInfoFireKey] as? Double).map { Date(timeIntervalSince1970: $0) }
            return (r.identifier, fire)
        }
        let stale = NotificationPlanner.staleIdentifiers(pending: pairs, keep: plans, covering: range)
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        for p in plans {
            let content = UNMutableNotificationContent()
            content.title = p.title
            content.body = p.body
            content.sound = .default
            content.userInfo = [
                NotificationPlanner.userInfoBlockKey: p.blockID.uuidString,
                NotificationPlanner.userInfoFireKey: p.fireDate.timeIntervalSince1970,
            ]
            if let t = p.todoID { content.userInfo[NotificationPlanner.userInfoTodoKey] = t.uuidString }
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: p.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            // 같은 식별자로 다시 요청하면 기존 알림이 바뀐다(예정 시간이 옮겨졌을 때).
            try? await center.add(UNNotificationRequest(identifier: p.identifier, content: content, trigger: trigger))
        }
    }
}
