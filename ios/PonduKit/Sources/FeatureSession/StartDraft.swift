import Foundation
import Observation
import PonduCore

/// 시작 화면에서 고르는 이어가는 일 한 줄. list_threads 응답에서 필요한 열만 읽는다.
struct ThreadChoice: Decodable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var shareTitle: String?
    var primaryCategory: String
    var defaultVisibility: String
    var archivedAt: Date?
    var defaultGroupId: UUID?
}

/// 시작 화면 상태. 서버 호출 없이 화면 값만 들고 있다가 시작을 누르면 컨트롤러가 가져간다.
@MainActor
@Observable
final class StartDraft {
    /// 시작 요청의 중복 방지 키. 사진 폴더 이름과 같다.
    let clientID = UUID()
    var category: String?
    var threadID: UUID?
    var todoID: UUID?
    var planBlockID: UUID?
    var joinedSessionID: UUID?
    var joinedWithName: String?
    /// 요청에서 넘어온 제목. 화면에 보여 주기만 하고 서버로 보내지 않는다(개인 제목은 공유 제목과 별개).
    var displayTitle: String?
    var shareTitle: String = ""
    var visibility: ShareTarget = .private

    /// 크루로 공개할 때 고르는 크루. `list_my_crews`로 받은 내 크루 중 하나다.
    var groupID: UUID?
    var crews: [CrewDTO] = []
    var crewsLoaded = false

    var threads: [ThreadChoice] = []
    var threadsLoading = true
    var threadsFailed = false

    var isCameraPresented = false
    var photo: ProcessedPhoto?
    var isProcessingPhoto = false
    var photoFailed = false
    @ObservationIgnored var photoTask: Task<Void, Never>?

    init(request: StartSessionRequest) {
        category = request.category?.rawValue
        threadID = request.threadID
        todoID = request.todoID
        planBlockID = request.planBlockID
        joinedSessionID = request.joinedSessionID
        joinedWithName = request.joinedWithName
        displayTitle = request.title
        // 같이 하기는 상대 카드에 함께 한 사람이 보여야 하므로 기본을 친구로 둔다.
        visibility = request.joinedSessionID == nil ? .private : .friends
    }

    var canStart: Bool { category != nil && !isProcessingPhoto && hasValidCrewChoice }

    /// 고를 수 있는 공개 대상. 내 크루가 없으면 `크루`는 숨긴다.
    var availableTargets: [ShareTarget] {
        ShareTarget.allCases.filter { $0 != .crew || !crews.isEmpty }
    }

    /// 서버로 보낼 크루 id. 크루 공개가 아니면 nil. 크루가 하나뿐이면 자동으로 그 크루, 여럿이면 고른 크루.
    var resolvedGroupID: UUID? {
        guard visibility == .crew else { return nil }
        if let groupID, crews.contains(where: { $0.id == groupID }) { return groupID }
        return crews.count == 1 ? crews[0].id : nil
    }

    /// 크루 공개인데 크루를 아직 못 정했으면 시작할 수 없다.
    var hasValidCrewChoice: Bool { visibility != .crew || resolvedGroupID != nil }

    func selectThread(_ id: UUID?) {
        threadID = id
        guard let id, let t = threads.first(where: { $0.id == id }) else { return }
        category = t.primaryCategory
        visibility = ShareTarget(rawValue: t.defaultVisibility) ?? .private
        groupID = t.defaultGroupId
        shareTitle = t.shareTitle ?? ""
        normalizeVisibility()
    }

    /// 크루가 없는데 크루 공개가 골라져 있으면 친구 공개로 바꾼다.
    private func normalizeVisibility() {
        if crewsLoaded, crews.isEmpty, visibility == .crew { visibility = .friends }
    }

    func loadCrews(using backend: Backend) async {
        do {
            crews = try await backend.rpc("list_my_crews", [:])
        } catch {
            crews = []
        }
        crewsLoaded = true
        normalizeVisibility()
    }

    func loadThreads(using backend: Backend) async {
        threadsLoading = true
        threadsFailed = false
        do {
            let all: [ThreadChoice] = try await backend.rpc("list_threads", [:])
            threads = all.filter { $0.archivedAt == nil }
            // 요청으로 넘어온 이어가는 일이면 기본값을 채운다(사용자가 이미 바꾼 값은 두기).
            if let id = threadID, let t = threads.first(where: { $0.id == id }) {
                if category == nil { category = t.primaryCategory }
                if joinedSessionID == nil {
                    visibility = ShareTarget(rawValue: t.defaultVisibility) ?? visibility
                    groupID = t.defaultGroupId
                }
                if shareTitle.isEmpty { shareTitle = t.shareTitle ?? "" }
                normalizeVisibility()
            }
        } catch {
            threadsFailed = true
        }
        threadsLoading = false
    }

    /// 촬영 직후 호출. 화면은 바로 돌아오고 줄이기는 뒤에서 한다.
    func capture(data: Data, directory: URL, processor: PhotoProcessing) {
        isProcessingPhoto = true
        photoFailed = false
        photoTask?.cancel()
        photoTask = Task { [weak self] in
            do {
                let result = try await processor.process(imageData: data, into: directory)
                self?.photo = result
            } catch {
                self?.photo = nil
                self?.photoFailed = true
            }
            self?.isProcessingPhoto = false
        }
    }

    func removePhoto() {
        photoTask?.cancel()
        photo = nil
        photoFailed = false
        isProcessingPhoto = false
    }
}

struct EndDraft: Equatable {
    var choice: EndChoice?
    var note: String = ""
}

struct AlertInfo: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}
