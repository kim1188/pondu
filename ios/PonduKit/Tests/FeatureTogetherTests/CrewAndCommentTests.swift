import XCTest
import PonduCore
@testable import FeatureTogether

@MainActor
final class CrewAndCommentTests: XCTestCase {
    nonisolated private static func crewJSON(id: UUID = UUID(), name: String = "스터디", role: String = "owner") -> [String: Any] {
        ["id": id.uuidString.lowercased(), "name": name, "invite_code": "ABCD1234", "member_count": 3, "role": role]
    }

    func testCrewNameValidation() {
        XCTAssertNil(CrewsModel.validName("   "))
        XCTAssertNil(CrewsModel.validName(String(repeating: "가", count: 31)))
        XCTAssertEqual(CrewsModel.validName("  스터디 "), "스터디")
    }

    func testCreateCrewAddsToListAndBadNameSkipsServer() async {
        let backend = FakeBackend()
        backend.on("create_crew") { _ in Fixtures.json(Self.crewJSON()) }
        let model = CrewsModel(backend: backend)

        _ = await model.create(name: " ")
        XCTAssertEqual(backend.calls(named: "create_crew").count, 0)

        let crew = await model.create(name: "스터디")
        XCTAssertNotNil(crew)
        XCTAssertEqual(model.crews.count, 1)
        XCTAssertEqual(backend.calls(named: "create_crew")[0].params["p_name"], .string("스터디"))
    }

    func testLeaveRevertsWhenServerFails() async {
        let backend = FakeBackend()
        backend.on("list_my_crews") { _ in Fixtures.json([Self.crewJSON()]) }
        backend.on("leave_crew") { _ in throw BackendError(code: "network") }
        let model = CrewsModel(backend: backend)
        await model.load()

        let ok = await model.leave(model.crews[0])

        XCTAssertFalse(ok)
        XCTAssertEqual(model.crews.count, 1)
    }

    func testInvalidInviteCodeShowsMessage() async {
        let backend = FakeBackend()
        backend.on("join_crew") { _ in throw BackendError(code: "invite_invalid") }
        let model = CrewsModel(backend: backend)

        let crew = await model.join(inviteCode: "nope")

        XCTAssertNil(crew)
        XCTAssertEqual(model.toast, "초대 코드를 다시 확인해 주세요.")
    }

    func testOnlyOwnerCanRemoveMembers() async throws {
        let owner = UUID(), member = UUID()
        let backend = FakeBackend()
        backend.on("list_crew_members") { _ in
            Fixtures.json([
                Fixtures.profile(id: owner, name: "운영", handle: "op").merging(["role": "owner"]) { $1 },
                Fixtures.profile(id: member, name: "멤버", handle: "mb").merging(["role": "member"]) { $1 },
            ])
        }
        backend.on("remove_crew_member") { _ in Data("null".utf8) }
        let crewDecoded = try Fixtures.decoder.decode(CrewDTO.self, from: Fixtures.json(Self.crewJSON(role: "member")))
        let asMember = CrewMembersModel(backend: backend, crew: crewDecoded)
        await asMember.load()
        await asMember.remove(asMember.members[1])
        XCTAssertEqual(backend.calls(named: "remove_crew_member").count, 0)

        let ownerCrew = try Fixtures.decoder.decode(CrewDTO.self, from: Fixtures.json(Self.crewJSON(role: "owner")))
        let asOwner = CrewMembersModel(backend: backend, crew: ownerCrew)
        await asOwner.load()
        await asOwner.remove(asOwner.members[1])
        XCTAssertEqual(asOwner.members.count, 1)
        XCTAssertEqual(backend.calls(named: "remove_crew_member").count, 1)
    }

    func testCommentAppearsImmediatelyAndIsRemovedOnFailure() async throws {
        let backend = FakeBackend()
        backend.on("add_comment") { _ in
            try await Task.sleep(for: .milliseconds(100))
            throw BackendError(code: "timeout")
        }
        let model = CommentsModel(backend: backend, sessionID: UUID())
        var delta = 0
        model.onCountChange = { delta += $0 }
        model.draft = "수고했어요"

        let task = Task { await model.send() }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.comments.count, 1)
        XCTAssertTrue(model.comments[0].isPending)
        await task.value

        XCTAssertTrue(model.comments.isEmpty)
        XCTAssertEqual(model.draft, "수고했어요")     // 입력을 되돌려 준다
        XCTAssertEqual(delta, 0)
        XCTAssertNotNil(model.toast)
    }
}
