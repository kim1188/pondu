import Foundation
import Observation
import PonduCore

/// 가입 흐름을 어디서 시작할지.
public enum AuthFlowStart: Equatable, Sendable {
    /// 로그인 정보가 있으면 프로필 만들기, 없으면 메일 입력.
    case automatic
    case email
    case profile
}

/// 메일 입력 → 코드 입력 → 프로필 만들기(M0 4.1절). 서버는 `Backend`, 로그인은 `AuthService`로만 부른다.
@MainActor
@Observable
final class AuthFlowModel {
    enum Step: Equatable {
        case email
        case code
        case profile
    }

    /// 메일 도메인 검사는 편의일 뿐이고, 가입 제한은 서버가 한다(M0 3.2절).
    static let allowedDomains = ["korea.ac.kr"]
    static let resendInterval = 60

    private(set) var step: Step

    // 메일 입력
    var email = ""
    private(set) var emailError: String?
    private(set) var isSendingCode = false

    // 코드 입력
    var code = ""
    private(set) var codeError: String?
    private(set) var isVerifying = false
    private(set) var resendRemaining = 0
    private(set) var sentEmail = ""

    let profileForm: ProfileFormModel

    private let auth: AuthService
    private let backend: Backend
    private let profiles: ProfileCache
    private let onSignedIn: (Profile) -> Void
    private let sleep: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored private var cooldownTask: Task<Void, Never>?

    init(deps: AppDependencies,
         start: AuthFlowStart = .automatic,
         onSignedIn: @escaping (Profile) -> Void,
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.auth = deps.auth
        self.backend = deps.backend
        self.profiles = deps.profiles
        self.onSignedIn = onSignedIn
        self.sleep = sleep
        self.profileForm = ProfileFormModel(backend: deps.backend, profiles: deps.profiles)
        switch start {
        case .email: step = .email
        case .profile: step = .profile
        case .automatic: step = deps.auth.currentUserID == nil ? .email : .profile
        }
    }

    // MARK: 입력 검사

    static func normalizedEmail(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func hasValidFormat(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !email.contains(" ") else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    /// 도메인이 허용 목록과 정확히 같을 때만 통과(`korea.ac.kr.evil.com`, `xkorea.ac.kr`은 거절).
    static func isAllowedDomain(_ email: String) -> Bool {
        guard let domain = email.split(separator: "@").last else { return false }
        return allowedDomains.contains(String(domain))
    }

    var canSendCode: Bool { !isSendingCode && !Self.normalizedEmail(email).isEmpty }
    var canResend: Bool { resendRemaining == 0 && !isSendingCode }

    // MARK: 메일 입력

    /// `인증 코드 받기`. 누르는 즉시 `isSendingCode`가 켜져서 버튼이 진행 상태로 바뀐다.
    func sendCode() async {
        guard !isSendingCode else { return }
        let normalized = Self.normalizedEmail(email)
        guard Self.hasValidFormat(normalized) else {
            emailError = "메일 주소 형식을 확인해 주세요."
            return
        }
        guard Self.isAllowedDomain(normalized) else {
            emailError = BackendError(code: "email_domain_not_allowed").userMessage
            return
        }
        isSendingCode = true
        emailError = nil
        defer { isSendingCode = false }
        do {
            try await auth.sendCode(email: normalized)
            sentEmail = normalized
            code = ""
            codeError = nil
            step = .code
            startCooldown()
        } catch is CancellationError {
            return
        } catch {
            emailError = error.ponduMessage
        }
    }

    /// `다시 보내기`. 60초에 한 번.
    func resend() async {
        guard canResend, !sentEmail.isEmpty else { return }
        isSendingCode = true
        codeError = nil
        defer { isSendingCode = false }
        do {
            try await auth.sendCode(email: sentEmail)
            code = ""
            startCooldown()
        } catch is CancellationError {
            return
        } catch {
            codeError = error.ponduMessage
        }
    }

    /// 메일 주소 고치기.
    func editEmail() {
        cooldownTask?.cancel()
        resendRemaining = 0
        code = ""
        codeError = nil
        step = .email
    }

    // MARK: 코드 입력

    /// 입력창에 들어온 글자를 숫자 6자리로 정리한다. 6자리가 차면 true.
    @discardableResult
    func codeChanged() -> Bool {
        let digits = String(code.filter(\.isNumber).prefix(6))
        if digits != code { code = digits }
        if !digits.isEmpty { codeError = nil }
        return digits.count == 6
    }

    func verifyCode() async {
        guard !isVerifying else { return }
        // 이미 로그인된 상태(프로필 확인만 실패했던 경우)면 코드를 다시 확인하지 않는다.
        let alreadySignedIn = auth.currentUserID != nil && step == .code && codeError == Self.profileCheckFailedMessage
        guard alreadySignedIn || code.count == 6 else { return }
        isVerifying = true
        codeError = nil
        defer { isVerifying = false }
        do {
            if !alreadySignedIn {
                try await auth.verify(email: sentEmail, code: code)
            }
        } catch is CancellationError {
            return
        } catch {
            codeError = error.ponduMessage
            if let backendError = error as? BackendError, backendError.code == "otp_invalid" || backendError.code == "otp_expired" {
                code = ""
            }
            return
        }
        await finishSignIn()
    }

    static let profileCheckFailedMessage = "프로필을 확인하지 못했어요. 다시 시도해 주세요."

    /// 로그인 직후: 프로필이 이미 있으면 바로 끝, 없으면 프로필 만들기.
    private func finishSignIn() async {
        do {
            let existing: Profile? = try await backend.rpc("get_my_profile", [:])
            if let existing {
                profiles.save(existing)
                cooldownTask?.cancel()
                onSignedIn(existing)
            } else {
                cooldownTask?.cancel()
                step = .profile
            }
        } catch is CancellationError {
            return
        } catch {
            codeError = Self.profileCheckFailedMessage
        }
    }

    // MARK: 프로필 만들기

    func enterProfileStep() async {
        await profileForm.loadDepartments()
    }

    func submitProfile() async {
        guard let profile = await profileForm.submit() else { return }
        onSignedIn(profile)
    }

    // MARK: 재전송 대기

    private func startCooldown() {
        cooldownTask?.cancel()
        resendRemaining = Self.resendInterval
        let sleep = self.sleep
        cooldownTask = Task { [weak self] in
            while !Task.isCancelled {
                await sleep(1)
                guard let self, !Task.isCancelled else { return }
                self.resendRemaining = max(0, self.resendRemaining - 1)
                if self.resendRemaining == 0 { return }
            }
        }
    }
}
