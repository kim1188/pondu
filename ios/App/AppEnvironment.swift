import Foundation
import UserNotifications
import PonduCore
import FeatureSession
import FeatureToday

/// 앱이 쓰는 객체를 한 곳에서 만들어 연결한다(조립만 하고 로직은 두지 않는다).
@MainActor
final class AppEnvironment {
    let backend: SupabaseBackend
    let sessionController: SessionController
    let imageLoader: ImageLoader
    let profileCache: ProfileCache
    let authStore: AuthStore
    let deps: AppDependencies
    /// 예정 시각 알림을 누르면 시작 화면으로 보낸다. `UNUserNotificationCenter.delegate`는 약한 참조라 여기서 붙들고 있는다.
    let notificationHandler: TodayNotificationHandler

    init(config: AppConfig) {
        let backend = SupabaseBackend(config: config.backend)
        let controller = SessionController(backend: backend)
        let imageLoader = ImageLoader(backend: backend)
        let profileCache = ProfileCache()

        self.backend = backend
        self.sessionController = controller
        self.imageLoader = imageLoader
        self.profileCache = profileCache
        self.authStore = AuthStore(auth: backend, backend: backend, cache: profileCache, onSignedOut: {
            // 다른 사람의 사진이 기기에 남지 않게 이미지 캐시를 비운다. 기능별 기기 저장분은 `.ponduDidSignOut` 알림으로 지운다.
            imageLoader.clearCaches()
        })
        self.deps = AppDependencies(backend: backend, sessions: controller, auth: backend, profiles: profileCache)

        // 알림을 눌러 앱이 켜지는 경우에도 받을 수 있도록 앱 시작 때 건다(탭 화면이 뜨기를 기다리지 않는다).
        let handler = TodayNotificationHandler { planBlockID, todoID in
            controller.presentStart(StartSessionRequest(todoID: todoID, planBlockID: planBlockID))
        }
        self.notificationHandler = handler
        UNUserNotificationCenter.current().delegate = handler
    }
}
