import SwiftUI
import PonduCore
import FeatureRecord
import FeatureTogether
import FeatureToday

/// 탭 3개: 오늘, 함께, 기록. 각 탭의 내용은 기능 타깃이 그린다.
struct MainTabView: View {
    enum Tab: Hashable {
        case today, together, record
    }

    let environment: AppEnvironment
    @State private var selection: Tab = .today
    @State private var showsSettings = false

    var body: some View {
        TabView(selection: $selection) {
            TodayRootView(deps: environment.deps)
                .tabItem { Label("오늘", systemImage: "sun.max") }
                .tag(Tab.today)
            TogetherRootView(deps: environment.deps)
                .tabItem { Label("함께", systemImage: "person.2") }
                .tag(Tab.together)
            RecordRootView(deps: environment.deps)
                .tabItem { Label("기록", systemImage: "chart.bar") }
                .tag(Tab.record)
        }
        // 설정 진입점. 각 탭이 자기 툴바에 `SettingsButton`을 놓고 싶으면 `\.showSettings`를 쓰면 된다.
        .environment(\.showSettings, { showsSettings = true })
        .overlay(alignment: .topLeading) {
            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("설정")
            .padding(.leading, Theme.Spacing.xs)
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                SettingsView(environment: environment)
            }
        }
    }
}
