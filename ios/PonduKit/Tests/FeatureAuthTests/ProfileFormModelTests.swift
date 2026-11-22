import XCTest
import PonduCore
@testable import FeatureAuth

@MainActor
final class ProfileFormModelTests: XCTestCase {
    private func makeModel(_ backend: FakeBackend, initial: Profile? = nil) -> ProfileFormModel {
        ProfileFormModel(backend: backend, profiles: ProfileCache(inMemory: true), initial: initial, debounceDelay: 0.05)
    }

    func testHandleRules() {
        XCTAssertTrue(ProfileRules.isValidHandle("abc"))
        XCTAssertTrue(ProfileRules.isValidHandle("a_1"))
        XCTAssertTrue(ProfileRules.isValidHandle(String(repeating: "a", count: 20)))
        XCTAssertFalse(ProfileRules.isValidHandle("ab"))
        XCTAssertFalse(ProfileRules.isValidHandle("한글아이디"))
        XCTAssertFalse(ProfileRules.isValidHandle("has space"))
        XCTAssertFalse(ProfileRules.isValidHandle(String(repeating: "a", count: 21)))
        XCTAssertFalse(ProfileRules.isValidHandle("ABC"))
        XCTAssertEqual(ProfileRules.normalizedHandle(" ABC "), "abc")
    }

    func testNameRules() {
        XCTAssertTrue(ProfileRules.isValidName("김"))
        XCTAssertFalse(ProfileRules.isValidName("   "))
        XCTAssertFalse(ProfileRules.isValidName(String(repeating: "가", count: 21)))
    }

    func testInvalidFormatNeverAsksServer() {
        let backend = FakeBackend()
        let model = makeModel(backend)
        model.handle = "ab"
        model.handleChanged()
        XCTAssertEqual(model.handleStatus, .invalidFormat)
        model.handle = ""
        model.handleChanged()
        XCTAssertEqual(model.handleStatus, .idle)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testAvailabilityCheckIsDebouncedToLastInput() async throws {
        let backend = FakeBackend()
        backend.register("is_handle_available", json: true)
        let model = makeModel(backend)
        for text in ["kim", "kim1", "kim12"] {
            model.handle = text
            model.handleChanged()
        }
        XCTAssertEqual(model.handleStatus, .checking)
        try await Task.sleep(nanoseconds: 300_000_000)
        let calls = backend.calls(named: "is_handle_available")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.params["p_handle"], "kim12")
        XCTAssertEqual(model.handleStatus, .available)
    }

    func testTakenHandleBlocksSubmit() async {
        let backend = FakeBackend()
        backend.register("is_handle_available", json: false)
        let model = makeModel(backend)
        model.handle = "taken"
        model.displayName = "김"
        await model.checkAvailability("taken")
        XCTAssertEqual(model.handleStatus, .taken)
        XCTAssertFalse(model.canSubmit)
    }

    func testServerRejectionAtSubmitShowsTaken() async {
        let backend = FakeBackend()
        backend.register("is_handle_available", json: true)
        backend.registerError("upsert_my_profile", code: "handle_taken")
        let model = makeModel(backend)
        model.handle = "kim"
        model.displayName = "김"
        await model.checkAvailability("kim")
        let result = await model.submit()
        XCTAssertNil(result)
        XCTAssertEqual(model.handleStatus, .taken)
        XCTAssertFalse(model.isSaving)
    }

    func testCheckFailureStillAllowsSubmitAndServerDecides() async {
        let backend = FakeBackend()
        backend.registerError("is_handle_available", code: "timeout")
        let model = makeModel(backend)
        model.handle = "kim"
        model.displayName = "김"
        await model.checkAvailability("kim")
        XCTAssertEqual(model.handleStatus, .checkFailed)
        XCTAssertTrue(model.canSubmit)
    }

    func testEditingKeepsOwnHandleAsUnchangedWithoutServerCall() {
        let backend = FakeBackend()
        let me = Profile(id: UUID(), handle: "Kim", displayName: "김", schoolId: UUID())
        let model = makeModel(backend, initial: me)
        XCTAssertTrue(model.isEditing)
        XCTAssertTrue(model.canSubmit)
        model.handle = "kim"
        model.handleChanged()
        XCTAssertEqual(model.handleStatus, .unchanged)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testLoadForEditingFetchesProfileAndDepartmentsTogether() async {
        let backend = FakeBackend()
        let id = UUID()
        backend.register("get_my_profile", value: Profile(id: id, handle: "kim", displayName: "김서버", schoolId: UUID()))
        backend.register("list_departments", json: [])
        let model = makeModel(backend)
        await model.loadForEditing()
        XCTAssertEqual(model.displayName, "김서버")
        XCTAssertEqual(model.departmentsState, .loaded)
        XCTAssertEqual(backend.calls.count, 2)
    }

    func testDepartmentLoadFailureIsReported() async {
        let backend = FakeBackend()
        backend.registerError("list_departments", code: "network")
        let model = makeModel(backend)
        await model.loadDepartments()
        XCTAssertEqual(model.departmentsState, .failed("인터넷 연결을 확인해 주세요."))
    }
}
