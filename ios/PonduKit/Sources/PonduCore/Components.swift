import SwiftUI

// MARK: - 뼈대 화면

private struct SkeletonModifier: ViewModifier {
    let isLoading: Bool
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isLoading {
            content
                .redacted(reason: .placeholder)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .overlay(shimmer)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1.5 }
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private var shimmer: some View {
        if reduceMotion {
            EmptyView()
        } else {
            GeometryReader { proxy in
                LinearGradient(colors: [.clear, Color.white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.6)
                    .offset(x: proxy.size.width * phase)
                    .blendMode(.plusLighter)
            }
            .allowsHitTesting(false)
            .clipped()
        }
    }
}

extension View {
    /// 로딩 중에는 내용을 뼈대(회색 자리)로 바꿔 보여 준다. 누를 수 없고 읽어 주지도 않는다.
    public func skeleton(_ isLoading: Bool) -> some View {
        modifier(SkeletonModifier(isLoading: isLoading))
    }
}

// MARK: - 오류·빈 상태

/// 실패했을 때 보여 주는 안내와 `다시 시도` 버튼.
public struct ErrorRetryView: View {
    private let message: String
    private let retry: () -> Void

    public init(message: String, onRetry: @escaping () -> Void) {
        self.message = message
        self.retry = onRetry
    }

    public init(error: Error, onRetry: @escaping () -> Void) {
        self.init(message: error.ponduMessage, onRetry: onRetry)
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(Theme.Palette.textSecondary)
                .accessibilityHidden(true)
            Text(message)
                .font(Theme.Font.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("다시 시도", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity)
    }
}

/// 비어 있는 목록의 안내.
public struct EmptyStateView: View {
    private let systemImage: String
    private let title: String
    private let message: String?

    public init(systemImage: String = "tray", title: String, message: String? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(Theme.Palette.textTertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Font.headline)
            if let message {
                Text(message)
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 설정 열기

private struct OpenSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// 앱 껍데기가 넣어 주는 `설정 열기` 동작. 탭 화면이 자기 툴바에 `SettingsButton`을 놓을 때 쓴다.
    public var showSettings: () -> Void {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
}

public struct SettingsButton: View {
    @Environment(\.showSettings) private var showSettings

    public init() {}

    public var body: some View {
        Button(action: showSettings) {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("설정")
    }
}

// MARK: - 권한 문구

/// Info.plist와 권한 안내 화면이 같은 문구를 쓰도록 한곳에 둔다.
public enum PermissionCopy {
    public static let camera = "세션 사진을 앱 안에서 바로 찍기 위해 카메라를 사용해요. 사진 보관함은 사용하지 않아요."
    public static let calendar = "일정이 있는 시간을 피해서 계획을 짜려고 캘린더를 읽어요. 일정의 제목과 메모는 기기 밖으로 나가지 않고, 바쁜 시간 구간만 계획에 쓰여요. 원본 일정은 수정하지 않아요."
    public static let notifications = "정해 둔 시간에 시작할 수 있도록 알림을 보내 드려요."
}
