import SwiftUI
import PonduCore

/// 가입·로그인 흐름: 메일 입력 → 코드 입력 → 프로필 만들기.
/// 로그인 정보가 있는데 프로필이 없으면(`start: .profile`) 곧바로 프로필 만들기부터 시작한다.
@MainActor
public struct AuthFlowView: View {
    @State private var model: AuthFlowModel

    /// - Parameters:
    ///   - start: 앱 껍데기가 진입 규칙에 따라 정해 준다. 기본값은 로그인 정보로 판단.
    ///   - onSignedIn: 로그인과 프로필이 모두 끝났을 때 한 번 불린다.
    public init(deps: AppDependencies, start: AuthFlowStart = .automatic, onSignedIn: @escaping (Profile) -> Void) {
        _model = State(initialValue: AuthFlowModel(deps: deps, start: start, onSignedIn: onSignedIn))
    }

    public var body: some View {
        Group {
            switch model.step {
            case .email:
                EmailStepView(model: model)
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)).combined(with: .opacity))
            case .code:
                CodeStepView(model: model)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .profile:
                ProfileStepView(model: model)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.step)
        .background(Theme.Palette.groupedBackground.ignoresSafeArea())
    }
}

// MARK: - 메일 입력

private struct EmailStepView: View {
    @Bindable var model: AuthFlowModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Spacer(minLength: Theme.Spacing.xxl)
            Text("고려대학교 메일로\n시작해요")
                .font(Theme.Font.largeTitle)
            Text("메일로 6자리 코드를 보내 드려요. 비밀번호는 필요 없어요.")
                .font(Theme.Font.callout)
                .foregroundStyle(Theme.Palette.textSecondary)

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                TextField("이름@korea.ac.kr", text: $model.email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused)
                    .padding(Theme.Spacing.m)
                    .background(Theme.Palette.card, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                    .onSubmit { send() }
                if let error = model.emailError {
                    Text(error)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.danger)
                        .accessibilityLabel("오류: \(error)")
                }
            }

            Button(action: send) {
                HStack(spacing: Theme.Spacing.s) {
                    if model.isSendingCode { ProgressView().tint(.white) }
                    Text(model.isSendingCode ? "보내는 중…" : "인증 코드 받기")
                        .font(Theme.Font.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.m)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSendCode)
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.l)
        .onAppear { focused = true }
    }

    private func send() {
        Task { await model.sendCode() }
    }
}

// MARK: - 코드 입력

private struct CodeStepView: View {
    @Bindable var model: AuthFlowModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Spacer(minLength: Theme.Spacing.xxl)
            Text("메일로 받은\n6자리 코드를 입력해 주세요")
                .font(Theme.Font.largeTitle)
            Text(model.sentEmail)
                .font(Theme.Font.callout)
                .foregroundStyle(Theme.Palette.textSecondary)

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                TextField("000000", text: $model.code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .padding(Theme.Spacing.m)
                    .background(Theme.Palette.card, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                    .disabled(model.isVerifying)
                    .onChange(of: model.code) { _, _ in
                        if model.codeChanged() { Task { await model.verifyCode() } }
                    }
                if model.isVerifying {
                    HStack(spacing: Theme.Spacing.s) {
                        ProgressView()
                        Text("확인 중…").font(Theme.Font.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                } else if let error = model.codeError {
                    Text(error)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.danger)
                        .accessibilityLabel("오류: \(error)")
                    if error == AuthFlowModel.profileCheckFailedMessage {
                        Button("다시 시도") { Task { await model.verifyCode() } }
                    }
                }
            }

            HStack {
                Button(model.resendRemaining > 0 ? "다시 보내기 (\(model.resendRemaining)초)" : "다시 보내기") {
                    Task { await model.resend() }
                }
                .disabled(!model.canResend)
                Spacer()
                Button("메일 주소 고치기") { model.editEmail() }
            }
            .font(Theme.Font.callout)
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.l)
        .onAppear { focused = true }
    }
}

// MARK: - 프로필 만들기

private struct ProfileStepView: View {
    @Bindable var model: AuthFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("프로필을 만들어요")
                    .font(Theme.Font.largeTitle)
                Text("친구가 나를 찾을 때 쓰는 아이디와 이름이에요.")
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.xxl)

            ProfileFormView(model: model.profileForm, submitTitle: "시작하기") {
                Task { await model.submitProfile() }
            }
        }
        .task { await model.enterProfileStep() }
    }
}
