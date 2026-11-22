import XCTest
import PonduCore
@testable import FeatureAuth

@MainActor
final class AuthFlowModelTests: XCTestCase {
    private func makeDeps(auth: FakeAuthService, backend: FakeBackend, cache: ProfileCache = ProfileCache(inMemory: true)) -> AppDependencies {
        AppDependencies(backend: backend, sessions: FakeSessionController(), auth: auth, profiles: cache)
    }

    private func profile(_ id: UUID = UUID(), handle: String = "kim") -> Profile {
        Profile(id: id, handle: handle, displayName: "김", schoolId: UUID())
    }

    private func makeModel(auth: FakeAuthService = FakeAuthService(), backend: FakeBackend = FakeBackend(userID: nil),
                           start: AuthFlowStart = .automatic,
                           onSignedIn: @escaping (Profile) -> Void = { _ in }) -> AuthFlowModel {
        AuthFlowModel(deps: makeDeps(auth: auth, backend: backend), start: start, onSignedIn: onSignedIn,
                      sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) })
    }

    // MARK: 시작 단계 (진입 규칙)

    func testStartStepFollowsLoginState() {
        XCTAssertEqual(makeModel(auth: FakeAuthService(userID: nil)).step, .email)
        XCTAssertEqual(makeModel(auth: FakeAuthService(userID: UUID())).step, .profile)
        XCTAssertEqual(makeModel(auth: FakeAuthService(userID: UUID()), start: .email).step, .email)
    }

    // MARK: 메일 입력

    func testEmailDomainRules() {
        XCTAssertTrue(AuthFlowModel.isAllowedDomain("a@korea.ac.kr"))
        XCTAssertTrue(AuthFlowModel.isAllowedDomain(AuthFlowModel.normalizedEmail("A@Korea.AC.kr")))
        XCTAssertFalse(AuthFlowModel.isAllowedDomain("a@gmail.com"))
        XCTAssertFalse(AuthFlowModel.isAllowedDomain("a@korea.ac.kr.evil.com"))
        XCTAssertFalse(AuthFlowModel.isAllowedDomain("a@xkorea.ac.kr"))
        XCTAssertFalse(AuthFlowModel.isAllowedDomain("a@KOREA.AC.KR.evil.com".lowercased()))
    }

    func testInvalidFormatAndOtherDomainShowMessageWithoutSending() async {
        let auth = FakeAuthService()
        let model = makeModel(auth: auth)
        model.email = "abc"
        await model.sendCode()
        XCTAssertEqual(model.emailError, "메일 주소 형식을 확인해 주세요.")
        model.email = "a@gmail.com"
        await model.sendCode()
        XCTAssertEqual(model.emailError, "고려대학교 메일(@korea.ac.kr)만 가입할 수 있어요.")
        XCTAssertTrue(auth.sentTo.isEmpty)
        XCTAssertEqual(model.step, .email)
    }

    func testSendCodeMovesToCodeStepAndStartsCooldown() async {
        let auth = FakeAuthService()
        let model = makeModel(auth: auth)
        model.email = "  A@Korea.AC.kr "
        await model.sendCode()
        XCTAssertEqual(auth.sentTo, ["a@korea.ac.kr"])
        XCTAssertEqual(model.step, .code)
        XCTAssertEqual(model.sentEmail, "a@korea.ac.kr")
        XCTAssertFalse(model.isSendingCode)
        XCTAssertGreaterThan(model.resendRemaining, 0)
        XCTAssertFalse(model.canResend)
    }

    func testSendFailureShowsMessageAndStaysOnEmail() async {
        let auth = FakeAuthService()
        auth.setSendError(code: "network")
        let model = makeModel(auth: auth)
        model.email = "a@korea.ac.kr"
        await model.sendCode()
        XCTAssertEqual(model.step, .email)
        XCTAssertEqual(model.emailError, "인터넷 연결을 확인해 주세요.")
        XCTAssertFalse(model.isSendingCode)
    }

    func testResendCooldownCountsDownToZero() async throws {
        let model = makeModel()
        model.email = "a@korea.ac.kr"
        await model.sendCode()
        for _ in 0..<400 where model.resendRemaining > 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(model.resendRemaining, 0)
        XCTAssertTrue(model.canResend)
    }

    func testEditEmailGoesBack() async {
        let model = makeModel()
        model.email = "a@korea.ac.kr"
        await model.sendCode()
        model.editEmail()
        XCTAssertEqual(model.step, .email)
        XCTAssertEqual(model.resendRemaining, 0)
    }

    // MARK: 코드 입력

    func testCodeInputKeepsSixDigits() {
        let model = makeModel()
        model.code = "12a3 4567"
        XCTAssertTrue(model.codeChanged())
        XCTAssertEqual(model.code, "123456")
    }

    func testWrongCodeShowsMessageAndClearsInput() async {
        let auth = FakeAuthService(validCode: "123456")
        let model = makeModel(auth: auth)
        model.email = "a@korea.ac.kr"
        await model.sendCode()
        model.code = "000000"
        await model.verifyCode()
        XCTAssertEqual(model.codeError, "코드가 맞지 않아요. 다시 입력해 주세요.")
        XCTAssertEqual(model.code, "")
        XCTAssertEqual(model.step, .code)
        XCTAssertFalse(model.isVerifying)
    }

    func testCorrectCodeWithExistingProfileFinishes() async {
        let id = UUID()
        let backend = FakeBackend(userID: nil)
        let existing = profile(id)
        backend.register("get_my_profile", value: existing)
        var signedIn: Profile?
        let model = makeModel(backend: backend, onSignedIn: { signedIn = $0 })
        model.email = "a@korea.ac.kr"
        await model.sendCode()
        model.code = "123456"
        await model.verifyCode()
        XCTAssertEqual(signedIn, existing)
    }

    func testCorrectCodeWithoutProfileGoesToProfileStep() async {
        let backend = FakeBackend(userID: nil)
        backend.register("get_my_profile", json: .null)
        var signedIn: Profile?
        let model = makeModel(backend: backend, onSignedIn: { signedIn = $0 })
        model.email = "a@korea.ac.kr"
        await model.sendCode()
        model.code = "123456"
        await model.verifyCode()
        XCTAssertEqual(model.step, .profile)
        XCTAssertNil(signedIn)
    }

    func testProfileCheckFailureCanRetryWithoutReverifying() async {
        let auth = FakeAuthService()
        let backend = FakeBackend(userID: nil)
        backend.registerError("get_my_profile", code: "network")
        let model = makeModel(auth: auth, backend: backend)
        model.email = "a@korea.ac.kr"
        await model.sendCode()
        model.code = "123456"
        await model.verifyCode()
        XCTAssertEqual(model.codeError, AuthFlowModel.profileCheckFailedMessage)
        XCTAssertEqual(auth.verifyAttempts, 1)
        backend.register("get_my_profile", json: .null)
        await model.verifyCode()
        XCTAssertEqual(auth.verifyAttempts, 1)       // 코드를 다시 확인하지 않는다
        XCTAssertEqual(model.step, .profile)
    }

    // MARK: 프로필 만들기

    func testSubmitProfileCallsUpsertAndFinishes() async throws {
        let backend = FakeBackend(userID: UUID())
        backend.register("is_handle_available", json: true)
        backend.register("list_departments", json: [["id": "11111111-1111-1111-1111-111111111111", "name": "컴퓨터학과"]])
        let saved = profile(handle: "kim_1")
        backend.register("upsert_my_profile", value: saved)
        var signedIn: Profile?
        let model = makeModel(auth: FakeAuthService(userID: UUID()), backend: backend, onSignedIn: { signedIn = $0 })
        XCTAssertEqual(model.step, .profile)
        await model.enterProfileStep()
        XCTAssertEqual(model.profileForm.departments.count, 1)

        model.profileForm.handle = "Kim_1"
        model.profileForm.handleChanged()
        XCTAssertEqual(model.profileForm.handle, "kim_1")
        await model.profileForm.checkAvailability("kim_1")
        model.profileForm.displayName = "김"
        model.profileForm.departmentID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        await model.submitProfile()

        XCTAssertEqual(signedIn, saved)
        let call = try XCTUnwrap(backend.calls(named: "upsert_my_profile").first)
        XCTAssertEqual(call.params["p_handle"], "kim_1")
        XCTAssertEqual(call.params["p_display_name"], "김")
        XCTAssertEqual(call.params["p_department_id"], "11111111-1111-1111-1111-111111111111")
    }
}
