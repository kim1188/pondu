import SwiftUI
import UIKit

/// 색, 간격, 글자 크기. 시스템 글꼴만 쓴다(내려받는 글꼴 없음).
public enum Theme {
    public enum Palette {
        public static let accent = dynamic(light: (0.13, 0.36, 0.92), dark: (0.42, 0.62, 1.0))
        public static let background = Color(uiColor: .systemBackground)
        public static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
        public static let groupedBackground = Color(uiColor: .systemGroupedBackground)
        public static let card = Color(uiColor: .secondarySystemGroupedBackground)
        public static let textPrimary = Color(uiColor: .label)
        public static let textSecondary = Color(uiColor: .secondaryLabel)
        public static let textTertiary = Color(uiColor: .tertiaryLabel)
        public static let separator = Color(uiColor: .separator)
        public static let success = Color(uiColor: .systemGreen)
        public static let warning = Color(uiColor: .systemOrange)
        public static let danger = Color(uiColor: .systemRed)

        static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
            Color(uiColor: UIColor { trait in
                let c = trait.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            })
        }
    }

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public enum Radius {
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
    }

    /// 시스템 글꼴 + Dynamic Type.
    public enum Font {
        public static let largeTitle = SwiftUI.Font.largeTitle.weight(.bold)
        public static let title = SwiftUI.Font.title2.weight(.bold)
        public static let headline = SwiftUI.Font.headline
        public static let body = SwiftUI.Font.body
        public static let callout = SwiftUI.Font.callout
        public static let caption = SwiftUI.Font.caption
        /// 타이머처럼 숫자가 바뀌는 글자는 자릿수 폭이 일정해야 흔들리지 않는다.
        public static let timer = SwiftUI.Font.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit()
        public static let badge = SwiftUI.Font.caption2.weight(.semibold)
    }
}

extension ActivityCategory {
    public var displayName: String {
        switch self {
        case .study: return "공부"
        case .coding: return "코딩"
        case .exercise: return "운동"
        case .project: return "프로젝트"
        case .ventureResearchIntern: return "창업·연구·인턴"
        case .parttime: return "알바"
        }
    }

    public var color: Color {
        switch self {
        case .study: return Color(uiColor: .systemBlue)
        case .coding: return Color(uiColor: .systemIndigo)
        case .exercise: return Color(uiColor: .systemOrange)
        case .project: return Color(uiColor: .systemTeal)
        case .ventureResearchIntern: return Color(uiColor: .systemPink)
        case .parttime: return Color(uiColor: .systemGreen)
        }
    }
}

/// `앱 촬영 첨부`, `사진 없는 기록`, `나중에 정정함`, `오프라인 시작` 같은 방식 표시 칩.
public struct RecordBadgeView: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(Theme.Font.badge)
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 3)
            .background(Theme.Palette.secondaryBackground, in: Capsule())
            .accessibilityLabel(text)
    }
}
