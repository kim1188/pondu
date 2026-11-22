import XCTest
@testable import PonduCore

@MainActor
final class AuthStoreTests: XCTestCase {
    private func makeProfile(_ id: UUID) -> Profile {
        Profile(id: id, handle: "kim", displayName: "김", schoolId: UUID())
    }

    func testNoLoginGoesToSignedOut() {
        let store = AuthStore(auth: FakeAuthService(userID: nil), backend: FakeBackend(userID: nil), cache: ProfileCache(inMemory: true))
        XCTAssertEqual(store.state, .launching)
        store.bootstrap()
        XCTAssertEqual(store.state, .signedOut)
    }

    func testCachedProfileShowsHomeImmediatelyThenRefreshes() async {
        let id = UUID()
        let cache = ProfileCache(inMemory: true)
        cache.save(makeProfile(id))
        let backend = FakeBackend(userID: id)
        var updated = makeProfile(id)
        updated.displayName = "김서버"
        backend.register("get_my_profile", value: updated)
        let store = AuthStore(auth: FakeAuthService(userID: id), backend: backend, cache: cache)
        store.bootstrap()
        XCTAssertEqual(store.state, .ready)               // 저장분으로 즉시 홈
        XCTAssertEqual(store.profile?.displayName, "김")
        XCTAssertTrue(store.isShowingCachedProfile)
        await store.refreshProfile()
        XCTAssertEqual(store.profile?.displayName, "김서버")
        XCTAssertFalse(store.isShowingCachedProfile)
    }

    func testOfflineKeepsCachedProfile() async {
        let id = UUID()
        let cache = ProfileCache(inMemory: true)
        cache.save(makeProfile(id))
        let backend = FakeBackend(userID: id)
        backend.registerError("get_my_profile", code: "network")
        let store = AuthStore(auth: FakeAuthService(userID: id), backend: backend, cache: cache)
        store.bootstrap()
        await store.refreshProfile()
        XCTAssertEqual(store.state, .ready)
        XCTAssertTrue(store.isShowingCachedProfile)
        XCTAssertEqual(store.lastError, .network)
    }

    func testLoggedInWithoutProfileNeedsProfile() async {
        let id = UUID()
        let backend = FakeBackend(userID: id)
        backend.register("get_my_profile", json: .null)
        let store = AuthStore(auth: FakeAuthService(userID: id), backend: backend, cache: ProfileCache(inMemory: true))
        store.bootstrap()
        await store.refreshProfile()
        XCTAssertEqual(store.state, .needsProfile)
    }

    func testOfflineWithoutCacheFailsToLoad() async {
        let id = UUID()
        let backend = FakeBackend(userID: id)
        backend.registerError("get_my_profile", code: "timeout")
        let store = AuthStore(auth: FakeAuthService(userID: id), backend: backend, cache: ProfileCache(inMemory: true))
        store.bootstrap()
        await store.refreshProfile()
        XCTAssertEqual(store.state, .loadFailed)
    }

    func testSignOutClearsCacheAndNotifies() async {
        let id = UUID()
        let cache = ProfileCache(inMemory: true)
        cache.save(makeProfile(id))
        let auth = FakeAuthService(userID: id)
        var cleaned = false
        let backend = FakeBackend(userID: id)
        backend.registerError("get_my_profile", code: "network")
        let store = AuthStore(auth: auth, backend: backend, cache: cache, onSignedOut: { cleaned = true })
        store.bootstrap()
        let notified = expectation(forNotification: .ponduDidSignOut, object: nil)
        await store.signOut()
        await fulfillment(of: [notified], timeout: 1)
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertNil(store.profile)
        XCTAssertNil(cache.load())
        XCTAssertEqual(auth.signOutCount, 1)
        XCTAssertTrue(cleaned)
    }

    func testProfileCompletedMakesReady() {
        let store = AuthStore(auth: FakeAuthService(userID: UUID()), backend: FakeBackend(), cache: ProfileCache(inMemory: true))
        store.profileCompleted(makeProfile(UUID()))
        XCTAssertEqual(store.state, .ready)
    }
}

final class ProfileCacheTests: XCTestCase {
    func testSaveLoadClearAndUserMatch() {
        let cache = ProfileCache(inMemory: true)
        let id = UUID()
        XCTAssertNil(cache.load())
        cache.save(Profile(id: id, handle: "a_b", displayName: "가나", schoolId: UUID()))
        XCTAssertEqual(cache.load()?.handle, "a_b")
        XCTAssertNotNil(cache.load(userID: id))
        XCTAssertNil(cache.load(userID: UUID()))     // 다른 사용자의 저장분은 쓰지 않는다
        cache.clear()
        XCTAssertNil(cache.load())
    }
}
