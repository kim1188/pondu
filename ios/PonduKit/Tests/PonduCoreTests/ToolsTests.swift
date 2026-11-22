import XCTest
@testable import PonduCore

final class ToolsTests: XCTestCase {
    func testInFlightMergesSameKey() async throws {
        let flight = InFlight<String, Int>()
        let counter = Locked(0)
        async let a = flight.run(key: "k") {
            counter.withValue { $0 += 1 }
            try await Task.sleep(nanoseconds: 100_000_000)
            return 7
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        async let b = flight.run(key: "k") {
            counter.withValue { $0 += 1 }
            return 8
        }
        let (x, y) = try await (a, b)
        XCTAssertEqual(x, 7)
        XCTAssertEqual(y, 7)
        XCTAssertEqual(counter.current, 1)
        let active = await flight.activeCount
        XCTAssertEqual(active, 0)
    }

    func testInFlightRunsAgainAfterFinish() async throws {
        let flight = InFlight<String, Int>()
        let counter = Locked(0)
        _ = try await flight.run(key: "k") { counter.withValue { $0 += 1 }; return 1 }
        _ = try await flight.run(key: "k") { counter.withValue { $0 += 1 }; return 1 }
        XCTAssertEqual(counter.current, 2)
    }

    func testDebouncerRunsOnlyLastAction() async throws {
        let debouncer = Debouncer(delay: .milliseconds(50))
        let ran = Locked<[Int]>([])
        debouncer.schedule { ran.withValue { $0.append(1) } }
        debouncer.schedule { ran.withValue { $0.append(2) } }
        debouncer.schedule { ran.withValue { $0.append(3) } }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(ran.current, [3])
    }

    func testDebouncerCancelStopsPendingAction() async throws {
        let debouncer = Debouncer(delay: .milliseconds(50))
        let ran = Locked(false)
        debouncer.schedule { ran.withValue { $0 = true } }
        debouncer.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(ran.current)
    }

    func testWithTimeoutThrowsTimeout() async {
        do {
            _ = try await withTimeout(0.05) { () -> Int in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return 1
            }
            XCTFail("시간 제한 오류가 나야 한다")
        } catch {
            XCTAssertEqual(error as? BackendError, .timeout)
        }
    }

    func testWithTimeoutReturnsValue() async throws {
        let value = try await withTimeout(1) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testDiskCacheStoreLoadAndTrim() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = DiskCache(directoryName: "t", maxBytes: 1000, baseDirectory: base)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertNil(cache.data(forKey: "a"))
        cache.store(Data(repeating: 1, count: 400), forKey: "a")
        XCTAssertEqual(cache.data(forKey: "a")?.count, 400)
        Thread.sleep(forTimeInterval: 0.02)
        cache.store(Data(repeating: 2, count: 400), forKey: "b")
        Thread.sleep(forTimeInterval: 0.02)
        cache.store(Data(repeating: 3, count: 400), forKey: "c")   // 1200 > 1000 → 가장 오래된 a가 지워진다
        XCTAssertNil(cache.data(forKey: "a"))
        XCTAssertNotNil(cache.data(forKey: "c"))
        XCTAssertLessThanOrEqual(cache.totalBytes, 1000)
        cache.removeAll()
        XCTAssertEqual(cache.totalBytes, 0)
    }

    func testErrorMappingFindsLongestContractCode() {
        struct Fake: Error { let message: String }
        XCTAssertEqual((ErrorMapping.map(Fake(message: "request_not_found")) as? BackendError)?.code, "request_not_found")
        XCTAssertEqual((ErrorMapping.map(Fake(message: "not_found")) as? BackendError)?.code, "not_found")
        XCTAssertEqual((ErrorMapping.map(Fake(message: "something else")) as? BackendError)?.code, "unknown")
        XCTAssertEqual((ErrorMapping.map(URLError(.notConnectedToInternet)) as? BackendError), .network)
        XCTAssertEqual((ErrorMapping.map(URLError(.timedOut)) as? BackendError), .timeout)
        XCTAssertTrue(ErrorMapping.map(URLError(.cancelled)) is CancellationError)
    }

    func testErrorMappingReadsFunctionBodies() {
        XCTAssertEqual(ErrorMapping.code(inBody: Data(#"{"error":"quota_exceeded"}"#.utf8)), "quota_exceeded")
        XCTAssertEqual(ErrorMapping.code(inBody: Data(#"{"error":{"code":"assistant_unavailable"}}"#.utf8)), "assistant_unavailable")
        XCTAssertNil(ErrorMapping.code(inBody: Data(#"{"error":"boom"}"#.utf8)))
    }

    func testAuthErrorMapping() {
        struct Fake: Error, CustomStringConvertible { let description: String }
        XCTAssertEqual((ErrorMapping.mapAuth(Fake(description: "Token has expired or is invalid")) as? BackendError)?.code, "otp_expired")
        XCTAssertEqual((ErrorMapping.mapAuth(Fake(description: "고려대학교 메일(@korea.ac.kr)만 가입할 수 있어요.")) as? BackendError)?.code, "email_domain_not_allowed")
        XCTAssertEqual((ErrorMapping.mapAuth(Fake(description: "email rate limit exceeded")) as? BackendError)?.code, "rate_limited")
    }
}
