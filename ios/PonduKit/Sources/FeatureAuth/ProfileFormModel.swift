import Foundation
import Observation
import PonduCore

/// 아이디·이름·학과 입력 규칙(M0 3.1절). 앱의 입력 검사는 편의일 뿐이고 최종 판단은 서버가 한다.
enum ProfileRules {
    static let handleRange = 3...20
    static let nameRange = 1...20
    private static let allowedHandleScalars = Set("abcdefghijklmnopqrstuvwxyz0123456789_".unicodeScalars)

    static func normalizedHandle(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func isValidHandle(_ text: String) -> Bool {
        handleRange.contains(text.count) && text.unicodeScalars.allSatisfy(allowedHandleScalars.contains)
    }

    static func trimmedName(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidName(_ text: String) -> Bool {
        nameRange.contains(trimmedName(text).count)
    }
}

/// 프로필 만들기와 프로필 수정이 같이 쓰는 입력 모델. 서버는 `Backend`로만 부른다.
@MainActor
@Observable
final class ProfileFormModel {
    enum HandleStatus: Equatable {
        case idle
        case invalidFormat
        case checking
        case available
        /// 수정 화면에서 원래 아이디 그대로일 때.
        case unchanged
        case taken
        /// 확인 요청이 실패했다. 저장할 때 서버가 다시 확인한다.
        case checkFailed
    }

    enum DepartmentsState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var handle = ""
    var displayName = ""
    var departmentID: UUID?

    private(set) var departments: [DepartmentDTO] = []
    private(set) var departmentsState: DepartmentsState = .idle
    private(set) var handleStatus: HandleStatus = .idle
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var isLoadingProfile = false

    private let backend: Backend
    private let profiles: ProfileCache
    private let debouncer: Debouncer
    private(set) var originalHandle: String?
    private var knownDepartmentName: String?

    init(backend: Backend, profiles: ProfileCache, initial: Profile? = nil, debounceDelay: TimeInterval = 0.3) {
        self.backend = backend
        self.profiles = profiles
        self.debouncer = Debouncer(delay: debounceDelay)
        if let initial { apply(initial) }
    }

    var isEditing: Bool { originalHandle != nil }

    var departmentName: String? {
        guard let departmentID else { return nil }
        return departments.first(where: { $0.id == departmentID })?.name ?? knownDepartmentName
    }

    var canSubmit: Bool {
        guard !isSaving, ProfileRules.isValidName(displayName) else { return false }
        switch handleStatus {
        case .available, .unchanged, .checkFailed: return true
        case .idle, .invalidFormat, .checking, .taken: return false
        }
    }

    // MARK: 불러오기

    /// 학과 목록을 받는다.
    func loadDepartments() async {
        guard departmentsState != .loading else { return }
        departmentsState = .loading
        do {
            departments = try await backend.rpc("list_departments", [:])
            departmentsState = .loaded
        } catch is CancellationError {
            departmentsState = .idle
        } catch {
            departmentsState = .failed(error.ponduMessage)
        }
    }

    /// 수정 화면: 서버의 내 프로필과 학과 목록을 동시에 받는다(서로 무관한 요청).
    func loadForEditing() async {
        isLoadingProfile = true
        defer { isLoadingProfile = false }
        async let profile: Profile? = backend.rpc("get_my_profile", [:])
        async let loadedDepartments: Void = loadDepartments()
        do {
            if let fetched = try await profile {
                apply(fetched)
                profiles.save(fetched)
            }
        } catch is CancellationError {
            // 화면을 벗어남
        } catch {
            errorMessage = error.ponduMessage
        }
        await loadedDepartments
    }

    // MARK: 아이디

    /// 아이디 입력이 바뀔 때마다 부른다. 입력이 0.3초 멈춘 뒤 한 번만 서버에 묻고, 이전 요청은 취소한다.
    func handleChanged() {
        let value = ProfileRules.normalizedHandle(handle)
        if value != handle { handle = value }
        errorMessage = nil
        guard !value.isEmpty else {
            debouncer.cancel()
            handleStatus = .idle
            return
        }
        guard ProfileRules.isValidHandle(value) else {
            debouncer.cancel()
            handleStatus = .invalidFormat
            return
        }
        if let originalHandle, originalHandle.lowercased() == value {
            debouncer.cancel()
            handleStatus = .unchanged
            return
        }
        handleStatus = .checking
        debouncer.schedule { [weak self] in
            await self?.checkAvailability(value)
        }
    }

    func checkAvailability(_ value: String) async {
        do {
            let available: Bool = try await backend.rpc("is_handle_available", ["p_handle": .string(value)])
            guard value == handle else { return }
            handleStatus = available ? .available : .taken
        } catch is CancellationError {
            return
        } catch {
            guard value == handle else { return }
            handleStatus = .checkFailed
        }
    }

    // MARK: 저장

    /// 서버에 저장하고 저장된 프로필을 돌려준다. 실패하면 이유를 `errorMessage`·`handleStatus`에 담고 nil.
    func submit() async -> Profile? {
        guard canSubmit else { return nil }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let params: [String: JSONValue] = [
                "p_handle": .string(handle),
                "p_display_name": .string(ProfileRules.trimmedName(displayName)),
                "p_department_id": .optional(departmentID),
            ]
            let saved: Profile = try await backend.rpc("upsert_my_profile", params)
            profiles.save(saved)
            apply(saved)
            return saved
        } catch is CancellationError {
            return nil
        } catch let error as BackendError {
            switch error.code {
            case "handle_taken": handleStatus = .taken
            case "handle_invalid": handleStatus = .invalidFormat
            default: errorMessage = error.userMessage
            }
            return nil
        } catch {
            errorMessage = error.ponduMessage
            return nil
        }
    }

    private func apply(_ profile: Profile) {
        originalHandle = profile.handle
        handle = profile.handle
        displayName = profile.displayName
        departmentID = profile.departmentId
        knownDepartmentName = profile.departmentName
        handleStatus = .unchanged
    }
}
