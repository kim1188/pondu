import SwiftUI
import PonduCore

@main
@MainActor
struct PonduApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let environment: AppEnvironment?

    init() {
        switch AppConfig.load() {
        case .success(let config): environment = AppEnvironment(config: config)
        case .failure: environment = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            if let environment {
                RootView(environment: environment)
                    .environment(\.imageLoader, environment.imageLoader)
                    .tint(Theme.Palette.accent)
                    .task {
                        // 첫 화면이 뜬 뒤에 측정 수집을 시작한다(SRD 4.2절).
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        MetricCollector.shared.start()
                    }
            } else {
                ConfigMissingView()
            }
        }
    }
}

/// 프로젝트 주소·공개용 키가 빌드에 들어오지 않았을 때 보이는 안내(개발자용).
private struct ConfigMissingView: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "gearshape.2").font(.largeTitle)
            Text("설정이 필요해요").font(Theme.Font.title)
            Text("ios/App/Config/Secrets.example.xcconfig를 Secrets.xcconfig로 복사해 프로젝트 주소와 공개용 키를 넣은 뒤 다시 빌드해 주세요.")
                .font(Theme.Font.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xl)
    }
}
