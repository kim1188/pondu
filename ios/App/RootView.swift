import SwiftUI
import PonduCore
import FeatureAuth
import FeatureSession

/// 진입 규칙(M0 4.1절): 로그인 정보 없음 → 메일 입력, 로그인됐지만 프로필 없음 → 프로필 만들기, 둘 다 있음 → 홈.
struct RootView: View {
    let environment: AppEnvironment
    private var authStore: AuthStore { environment.authStore }

    var body: some View {
        Group {
            switch authStore.state {
            case .launching:
                SplashView()
            case .signedOut:
                AuthFlowView(deps: environment.deps, start: .email) { authStore.profileCompleted($0) }
            case .needsProfile:
                AuthFlowView(deps: environment.deps, start: .profile) { authStore.profileCompleted($0) }
            case .ready:
                SessionHostView(controller: environment.sessionController) {
                    MainTabView(environment: environment)
                }
            case .loadFailed:
                LoadFailedView(message: (authStore.lastError ?? .unknown).userMessage,
                               retry: { authStore.refresh() },
                               signOut: { Task { await authStore.signOut() } })
            }
        }
        .animation(.easeInOut(duration: 0.2), value: authStore.state)
        .onAppear {
            Signpost.event("FirstScreen")
            authStore.bootstrap()
        }
    }
}

private struct SplashView: View {
    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()
            ProgressView()
        }
    }
}

/// 로그인은 돼 있는데 저장된 프로필이 없고 서버에도 닿지 못했을 때.
private struct LoadFailedView: View {
    let message: String
    let retry: () -> Void
    let signOut: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            ErrorRetryView(message: message, retry: retry)
            Button("로그아웃", role: .destructive, action: signOut)
        }
    }
}
