import Foundation
import Observation

/// 앱 전체의 로그인·프로필 상태. 진입 규칙(M0 4.1절)을 한 곳에서 정한다.
/// 로그인 정보 없음 → `signedOut`, 로그인됐지만 프로필 없음 → `needsProfile`, 둘 다 있음 → `ready`.
@MainActor
@Observable
public final class AuthStore {
    public enum State: Equatable {
        /// 첫 판단 전. 스플래시를 보여 준다.
        case launching
        case signedOut
        case needsProfile
        case ready
        /// 로그인은 돼 있는데 저장된 프로필도 없고 서버에도 닿지 못했다.
        case loadFailed
    }

    public private(set) var state: State = .launching
    public private(set) var profile: Profile?
    /// 서버를 못 불러서 저장분으로 보여 주는 중이면 true.
    public private(set) var isShowingCachedProfile = false
    public private(set) var lastError: BackendError?

    private let auth: AuthService
    private let backend: Backend
    private let cache: ProfileCache
    private let onSignedOut: @MainActor () -> Void
    private var observer: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    /// - Parameter onSignedOut: 로그아웃 때 지울 기기 저장분(이미지 캐시 등)을 정리하는 동작.
    public init(auth: AuthService, backend: Backend, cache: ProfileCache, onSignedOut: @escaping @MainActor () -> Void = {}) {
        self.auth = auth
        self.backend = backend
        self.cache = cache
        self.onSignedOut = onSignedOut
    }

    /// 앱을 켤 때 한 번. 저장된 프로필이 있으면 기다리지 않고 바로 `ready`가 된다.
    public func bootstrap() {
        guard state == .launching else { return }
        startObserving()
        guard let userID = auth.currentUserID else {
            state = .signedOut
            return
        }
        if let cached = cache.load(userID: userID) {
            profile = cached
            isShowingCachedProfile = true
            state = .ready
        }
        refresh()
    }

    /// 서버 값으로 프로필을 갱신한다. 실패해도 저장분이 있으면 화면은 그대로 둔다.
    public func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { await refreshProfile() }
    }

    public func refreshProfile() async {
        guard !Task.isCancelled else { return }
        guard let userID = auth.currentUserID else {
            await finishSignOut()
            return
        }
        do {
            let fetched: Profile? = try await backend.rpc("get_my_profile", [:])
            try Task.checkCancellation()
            guard auth.currentUserID == userID else { return }
            lastError = nil
            if let fetched {
                cache.save(fetched)
                profile = fetched
                isShowingCachedProfile = false
                state = .ready
            } else {
                cache.clear()
                profile = nil
                state = .needsProfile
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, auth.currentUserID == userID else { return }
            let backendError = (error as? BackendError) ?? .unknown
            lastError = backendError
            if backendError == .notAuthenticated {
                await finishSignOut()
            } else if profile == nil {
                state = .loadFailed
            }
            // 저장분이 있으면 그대로 두고 `isShowingCachedProfile`로 안내한다.
        }
    }

    /// 가입·프로필 만들기가 끝났을 때.
    public func profileCompleted(_ newProfile: Profile) {
        cache.save(newProfile)
        profile = newProfile
        isShowingCachedProfile = false
        lastError = nil
        state = .ready
    }

    /// 프로필을 고친 뒤 기기 저장분에서 다시 읽는다.
    public func reloadFromCache() {
        if let cached = cache.load(userID: auth.currentUserID) {
            profile = cached
        }
    }

    public func signOut() async {
        // 서버 응답이 늦어도 3초 뒤에는 기기 쪽 로그아웃을 끝낸다.
        let auth = self.auth
        try? await withTimeout(3) { try await auth.signOut() }
        await finishSignOut()
    }

    // MARK: 내부

    private func finishSignOut() async {
        // 로그아웃 동작과 로그인 상태 관찰이 겹쳐 두 번 불려도 한 번만 처리한다.
        guard state != .signedOut else { return }
        refreshTask?.cancel()
        cache.clear()
        profile = nil
        isShowingCachedProfile = false
        lastError = nil
        state = .signedOut
        onSignedOut()
        NotificationCenter.default.post(name: .ponduDidSignOut, object: nil)
    }

    private func startObserving() {
        guard observer == nil else { return }
        let stream = auth.userChanges()
        observer = Task { [weak self] in
            for await userID in stream {
                guard let self else { return }
                if userID == nil, self.state != .signedOut, self.state != .launching {
                    await self.finishSignOut()
                }
            }
        }
    }
}
