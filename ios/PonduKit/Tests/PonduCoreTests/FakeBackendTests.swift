import XCTest
@testable import PonduCore

final class FakeBackendTests: XCTestCase {
    func testRegisteredResponseAndCallLog() async throws {
        let backend = FakeBackend()
        backend.register("is_handle_available", json: true)
        let ok: Bool = try await backend.rpc("is_handle_available", ["p_handle": "kim"])
        XCTAssertTrue(ok)
        XCTAssertEqual(backend.calls(named: "is_handle_available").count, 1)
        XCTAssertEqual(backend.calls.first?.params["p_handle"], "kim")
    }

    func testHandlerSeesParams() async throws {
        let backend = FakeBackend()
        backend.register("echo") { params in params["p_x"] ?? .null }
        let value: String = try await backend.rpc("echo", ["p_x": "hello"])
        XCTAssertEqual(value, "hello")
    }

    func testRegisterValueEncodesDTO() async throws {
        let backend = FakeBackend()
        let profile = Profile(id: UUID(), handle: "kim", displayName: "김", schoolId: UUID())
        backend.register("get_my_profile", value: profile)
        let loaded: Profile? = try await backend.rpc("get_my_profile", [:])
        XCTAssertEqual(loaded, profile)
    }

    func testErrorsUnregisteredAndVoid() async throws {
        let backend = FakeBackend()
        backend.registerError("start_session", code: "session_already_active")
        do {
            try await backend.rpcVoid("start_session", [:])
            XCTFail()
        } catch {
            XCTAssertEqual(error as? BackendError, BackendError(code: "session_already_active"))
        }
        try await backend.rpcVoid("unregistered_void", [:])   // 등록 없이도 성공하고 기록만 남는다
        XCTAssertEqual(backend.calls(named: "unregistered_void").count, 1)
        do {
            let _: Int = try await backend.rpc("unregistered", [:])
            XCTFail()
        } catch {
            XCTAssertTrue((error as? BackendError)?.code.hasPrefix("fake_unregistered") ?? false)
        }
    }

    func testStreamEvents() async throws {
        let backend = FakeBackend()
        backend.registerStream(function: "assistant", events: [
            (name: "message_delta", data: ["text": "안녕"]),
            (name: "proposal", data: ["proposal_id": "p1"]),
        ])
        var names: [String] = []
        for try await event in backend.stream(function: "assistant", body: ["kind": "capture"]) { names.append(event.name) }
        XCTAssertEqual(names, ["message_delta", "proposal"])
        XCTAssertEqual(backend.calls(named: "assistant").first?.kind, .stream)
    }

    func testUploadAndSignedURL() async throws {
        let backend = FakeBackend()
        try await backend.upload(path: "u/s/full.heic", fileURL: URL(fileURLWithPath: "/tmp/x.heic"), contentType: "image/heic")
        XCTAssertEqual(backend.calls(named: "u/s/full.heic").first?.kind, .upload)
        backend.setUploadError(code: "network")
        do {
            try await backend.upload(path: "p", fileURL: URL(fileURLWithPath: "/tmp/x"), contentType: "image/heic")
            XCTFail()
        } catch {
            XCTAssertEqual(error as? BackendError, .network)
        }
        let url = try await backend.signedURL(path: "a/b.heic")
        XCTAssertTrue(url.absoluteString.contains("a/b.heic"))
    }
}
