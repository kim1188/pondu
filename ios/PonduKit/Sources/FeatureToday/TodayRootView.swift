import SwiftUI
import UserNotifications
import PonduCore

/// 알림을 누르면 시작 화면으로 보낸다. 앱 쪽에서 `UNUserNotificationCenter.current().delegate`에 걸어도 되고,
/// 걸지 않았으면 `TodayRootView`가 나타날 때 스스로 건다.
public final class TodayNotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    private let onOpen: @MainActor (UUID?, UUID?) -> Void
    public init(onOpen: @escaping @MainActor (UUID?, UUID?) -> Void) { self.onOpen = onOpen }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let block = (info[NotificationPlanner.userInfoBlockKey] as? String).flatMap(UUID.init(uuidString:)) else { return }
        let todo = (info[NotificationPlanner.userInfoTodoKey] as? String).flatMap(UUID.init(uuidString:))
        await onOpen(block, todo)
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@MainActor
public struct TodayRootView: View {
    @State private var model: TodayModel
    @State private var notificationHandler: TodayNotificationHandler?
    @Environment(\.scenePhase) private var scenePhase

    public init(deps: AppDependencies) {
        let m = TodayModel(
            backend: deps.backend, sessions: deps.sessions, now: deps.now,
            store: FileSnapshotStore(userID: deps.backend.currentUserID),
            calendar: EventKitCalendarReader(), notifier: LocalNotificationScheduler())
        _model = State(initialValue: m)
    }

    public var body: some View {
        TodayView(model: model)
            .task { await model.load() }
            .onAppear(perform: installNotificationHandler)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.load() } }      // 복귀 때 캘린더와 오늘을 다시 받는다
            }
            .onReceive(NotificationCenter.default.publisher(for: SessionEndSignal.notificationName)) { note in
                if let signal = SessionEndSignal(userInfo: note.userInfo) { model.receiveSessionEnd(signal) }
            }
    }

    private func installNotificationHandler() {
        let center = UNUserNotificationCenter.current()
        guard center.delegate == nil else { return }
        let handler = TodayNotificationHandler { [model] block, todo in model.startFromNotification(blockID: block, todoID: todo) }
        notificationHandler = handler
        center.delegate = handler
    }
}
