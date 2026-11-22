import Foundation
import Observation
import PonduCore

/// 내 크루 목록과 만들기·초대 코드 입력.
@MainActor
@Observable
final class CrewsModel {
    enum Phase: Equatable { case loading, ready, failed }

    private(set) var crews: [CrewDTO] = []
    private(set) var phase: Phase = .loading
    var toast: String?
    @ObservationIgnored private let backend: Backend

    init(backend: Backend) {
        self.backend = backend
    }

    func load() async {
        if crews.isEmpty { phase = .loading }
        do {
            crews = try await backend.rpc("list_my_crews", [:])
            phase = .ready
        } catch {
            if crews.isEmpty { phase = .failed } else { toast = TogetherText.message(for: error) }
        }
    }

    /// 이름이 비었거나 너무 길면 서버에 보내지 않는다.
    static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...30).contains(name.count) ? name : nil
    }

    @discardableResult
    func create(name raw: String) async -> CrewDTO? {
        guard let name = Self.validName(raw) else {
            toast = "크루 이름은 1~30자로 정해 주세요."
            return nil
        }
        do {
            let crew: CrewDTO = try await backend.rpc("create_crew", ["p_name": .string(name)])
            crews.insert(crew, at: 0)
            phase = .ready
            return crew
        } catch {
            toast = TogetherText.message(for: error)
            return nil
        }
    }

    @discardableResult
    func join(inviteCode raw: String) async -> CrewDTO? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        do {
            let crew: CrewDTO = try await backend.rpc("join_crew", ["p_invite_code": .string(code)])
            if !crews.contains(where: { $0.id == crew.id }) { crews.insert(crew, at: 0) }
            phase = .ready
            return crew
        } catch {
            toast = TogetherText.message(for: error)
            return nil
        }
    }

    func leave(_ crew: CrewDTO) async -> Bool {
        let before = crews
        crews.removeAll { $0.id == crew.id }
        do {
            try await backend.rpcVoid("leave_crew", ["p_group_id": TogetherParam.id(crew.id)])
            return true
        } catch {
            crews = before
            toast = TogetherText.message(for: error)
            return false
        }
    }
}

/// 크루 구성원 보기와 내보내기.
@MainActor
@Observable
final class CrewMembersModel {
    enum Phase: Equatable { case loading, ready, failed }

    private(set) var members: [CrewMemberDTO] = []
    private(set) var phase: Phase = .loading
    var toast: String?
    @ObservationIgnored private let backend: Backend
    let crew: CrewDTO

    init(backend: Backend, crew: CrewDTO) {
        self.backend = backend
        self.crew = crew
    }

    var isOwner: Bool { crew.role == "owner" }

    func load() async {
        if members.isEmpty { phase = .loading }
        do {
            members = try await backend.rpc("list_crew_members", ["p_group_id": TogetherParam.id(crew.id)])
            phase = .ready
        } catch {
            if members.isEmpty { phase = .failed } else { toast = TogetherText.message(for: error) }
        }
    }

    func remove(_ member: CrewMemberDTO) async {
        guard isOwner, !member.isOwner else { return }
        let before = members
        members.removeAll { $0.id == member.id }
        do {
            try await backend.rpcVoid("remove_crew_member", [
                "p_group_id": TogetherParam.id(crew.id),
                "p_user_id": TogetherParam.id(member.id),
            ])
        } catch {
            members = before
            toast = TogetherText.message(for: error)
        }
    }
}
