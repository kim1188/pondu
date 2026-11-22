import SwiftUI
import PonduCore
import FeatureAuth

/// 설정: 내 프로필 보기·수정, 로그아웃(M0 4.1절).
struct SettingsView: View {
    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsSignOut = false
    @State private var isSigningOut = false

    private var authStore: AuthStore { environment.authStore }

    var body: some View {
        List {
            Section("내 프로필") {
                if let profile = authStore.profile {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(profile.displayName).font(Theme.Font.headline)
                        Text("@\(profile.handle)").font(Theme.Font.callout).foregroundStyle(Theme.Palette.textSecondary)
                        if let department = profile.departmentName {
                            Text(department).font(Theme.Font.caption).foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                    .accessibilityElement(children: .combine)
                    NavigationLink("프로필 수정") {
                        ProfileEditView(deps: environment.deps) { _ in authStore.reloadFromCache() }
                    }
                } else {
                    Text("프로필을 불러오는 중이에요.").foregroundStyle(Theme.Palette.textSecondary).skeleton(true)
                }
                if authStore.isShowingCachedProfile {
                    Text("연결되지 않아 기기에 저장된 정보를 보여 주고 있어요. 연결되면 새로 고쳐져요.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }

            Section {
                Text("캘린더 일정의 제목과 메모는 기기 밖으로 나가지 않아요. 계획을 짤 때는 바쁜 시간 구간만 쓰여요.")
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } header: {
                Text("내 정보")
            }

            Section {
                Button(role: .destructive) {
                    confirmsSignOut = true
                } label: {
                    HStack {
                        Text(isSigningOut ? "로그아웃 중…" : "로그아웃")
                        if isSigningOut { ProgressView() }
                    }
                }
                .disabled(isSigningOut)
            } footer: {
                Text("로그아웃하면 이 기기에 저장된 내 정보가 지워져요.")
            }

            Section {
                LabeledContent("버전", value: Self.versionText)
            }
        }
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
        }
        .confirmationDialog("로그아웃할까요?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("로그아웃", role: .destructive) {
                isSigningOut = true
                Task {
                    await authStore.signOut()
                    isSigningOut = false
                }
            }
            Button("취소", role: .cancel) {}
        }
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }
}
