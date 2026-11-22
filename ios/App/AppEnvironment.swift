import Foundation
import PonduCore
import FeatureSession

/// 앱이 쓰는 객체를 한 곳에서 만들어 연결한다(조립만 하고 로직은 두지 않는다).
@MainActor
final class AppEnvironment {
    let backend: SupabaseBackend
    let sessionController: SessionController
    let imageLoader: ImageLoader
    let profileCache: ProfileCache
    let authStore: AuthStore
    let deps: AppDependencies

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
    }
}
