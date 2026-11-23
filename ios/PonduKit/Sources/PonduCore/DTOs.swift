// 자동 생성 아님: 계약 3절 JSON 모양과 일대일. 수정하면 서버 계약과 맞는지 확인할 것.
import Foundation

/// 서버 ProfileCard. 다른 사람에게 보이는 최소 정보.
public struct ProfileCard: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var handle: String
    public var displayName: String
    public var avatarPath: String?
    public var departmentName: String?

    public init(id: UUID = UUID(), handle: String = "", displayName: String = "", avatarPath: String? = nil, departmentName: String? = nil) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarPath = avatarPath
        self.departmentName = departmentName
    }
}

/// 서버 Profile (ProfileCard + 학교·학과 id).
public struct Profile: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var handle: String
    public var displayName: String
    public var avatarPath: String?
    public var departmentName: String?
    public var schoolId: UUID
    public var departmentId: UUID?

    public init(id: UUID = UUID(), handle: String = "", displayName: String = "", avatarPath: String? = nil, departmentName: String? = nil, schoolId: UUID = UUID(), departmentId: UUID? = nil) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarPath = avatarPath
        self.departmentName = departmentName
        self.schoolId = schoolId
        self.departmentId = departmentId
    }

    public var card: ProfileCard {
        ProfileCard(id: id, handle: handle, displayName: displayName, avatarPath: avatarPath, departmentName: departmentName)
    }
}

/// list_departments의 한 행.
public struct DepartmentDTO: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String = "") {
        self.id = id
        self.name = name
    }
}

/// 서버 Session.
public struct SessionDTO: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var userId: UUID
    public var threadId: UUID?
    public var todoId: UUID?
    public var planBlockId: UUID?
    public var joinedSessionId: UUID?
    public var primaryCategory: ActivityCategory
    public var tags: [String]
    public var startedAt: Date
    public var endedAt: Date?
    public var pausedAt: Date?
    public var pausedSeconds: Int
    public var durationSeconds: Int
    public var status: SessionStatus
    public var outcome: SessionOutcome?
    public var captureMode: CaptureMode
    public var photoPath: String?
    public var photoThumbPath: String?
    public var shareTitle: String?
    public var progressNote: String?
    public var visibility: ShareVisibility
    public var endCorrected: Bool
    public var offlineStartedAt: Date?
    /// 크루에게 공개한 세션이면 그 크루의 id. 그 밖에는 nil(옛 서버 응답에도 없다).
    public var groupId: UUID?

    public init(id: UUID = UUID(), userId: UUID = UUID(), threadId: UUID? = nil, todoId: UUID? = nil, planBlockId: UUID? = nil, joinedSessionId: UUID? = nil, primaryCategory: ActivityCategory = .study, tags: [String] = [], startedAt: Date = Date(), endedAt: Date? = nil, pausedAt: Date? = nil, pausedSeconds: Int = 0, durationSeconds: Int = 0, status: SessionStatus = .live, outcome: SessionOutcome? = nil, captureMode: CaptureMode = .noPhoto, photoPath: String? = nil, photoThumbPath: String? = nil, shareTitle: String? = nil, progressNote: String? = nil, visibility: ShareVisibility = .private, endCorrected: Bool = false, offlineStartedAt: Date? = nil, groupId: UUID? = nil) {
        self.id = id
        self.userId = userId
        self.threadId = threadId
        self.todoId = todoId
        self.planBlockId = planBlockId
        self.joinedSessionId = joinedSessionId
        self.primaryCategory = primaryCategory
        self.tags = tags
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pausedAt = pausedAt
        self.pausedSeconds = pausedSeconds
        self.durationSeconds = durationSeconds
        self.status = status
        self.outcome = outcome
        self.captureMode = captureMode
        self.photoPath = photoPath
        self.photoThumbPath = photoThumbPath
        self.shareTitle = shareTitle
        self.progressNote = progressNote
        self.visibility = visibility
        self.endCorrected = endCorrected
        self.offlineStartedAt = offlineStartedAt
        self.groupId = groupId
    }

    private enum CodingKeys: String, CodingKey {
        case id, userId, threadId, todoId, planBlockId, joinedSessionId, primaryCategory, tags, startedAt, endedAt
        case pausedAt, pausedSeconds, durationSeconds, status, outcome, captureMode, photoPath, photoThumbPath
        case shareTitle, progressNote, visibility, endCorrected, offlineStartedAt, groupId
    }

    /// `duration_seconds`는 종료 확인이 필요한 세션(`needs_confirmation`)에서 null이다(계약 보정 R13). 그때는 0으로 읽는다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        userId = try c.decode(UUID.self, forKey: .userId)
        threadId = try c.decodeIfPresent(UUID.self, forKey: .threadId)
        todoId = try c.decodeIfPresent(UUID.self, forKey: .todoId)
        planBlockId = try c.decodeIfPresent(UUID.self, forKey: .planBlockId)
        joinedSessionId = try c.decodeIfPresent(UUID.self, forKey: .joinedSessionId)
        primaryCategory = try c.decode(ActivityCategory.self, forKey: .primaryCategory)
        tags = try c.decode([String].self, forKey: .tags)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        pausedAt = try c.decodeIfPresent(Date.self, forKey: .pausedAt)
        pausedSeconds = try c.decode(Int.self, forKey: .pausedSeconds)
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 0
        status = try c.decode(SessionStatus.self, forKey: .status)
        outcome = try c.decodeIfPresent(SessionOutcome.self, forKey: .outcome)
        captureMode = try c.decode(CaptureMode.self, forKey: .captureMode)
        photoPath = try c.decodeIfPresent(String.self, forKey: .photoPath)
        photoThumbPath = try c.decodeIfPresent(String.self, forKey: .photoThumbPath)
        shareTitle = try c.decodeIfPresent(String.self, forKey: .shareTitle)
        progressNote = try c.decodeIfPresent(String.self, forKey: .progressNote)
        visibility = try c.decode(ShareVisibility.self, forKey: .visibility)
        endCorrected = try c.decode(Bool.self, forKey: .endCorrected)
        offlineStartedAt = try c.decodeIfPresent(Date.self, forKey: .offlineStartedAt)
        groupId = try c.decodeIfPresent(UUID.self, forKey: .groupId)
    }

    public var isActive: Bool { status == .live || status == .paused }
    public var recordBadges: [String] {
        RecordBadge.labels(captureMode: captureMode, endCorrected: endCorrected, offlineStarted: offlineStartedAt != nil)
    }
}

/// 서버 Thread (이어가는 일).
public struct ThreadDTO: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var shareTitle: String?
    public var primaryCategory: ActivityCategory
    public var defaultVisibility: ShareVisibility
    public var archivedAt: Date?
    /// 크루 공개가 기본인 일이면 기본 크루의 id.
    public var defaultGroupId: UUID?

    public init(id: UUID = UUID(), title: String = "", shareTitle: String? = nil, primaryCategory: ActivityCategory = .study, defaultVisibility: ShareVisibility = .private, archivedAt: Date? = nil, defaultGroupId: UUID? = nil) {
        self.id = id
        self.title = title
        self.shareTitle = shareTitle
        self.primaryCategory = primaryCategory
        self.defaultVisibility = defaultVisibility
        self.archivedAt = archivedAt
        self.defaultGroupId = defaultGroupId
    }
}

/// 서버 Todo.
public struct TodoDTO: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var threadId: UUID?
    public var title: String
    public var dueAt: Date?
    public var dueHasTime: Bool
    public var estimateMin: Int?
    public var status: TodoStatus
    public var completedAt: Date?
    public var completionSource: String?
    public var source: String?
    public var sourceRef: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), threadId: UUID? = nil, title: String = "", dueAt: Date? = nil, dueHasTime: Bool = false, estimateMin: Int? = nil, status: TodoStatus = .open, completedAt: Date? = nil, completionSource: String? = nil, source: String? = nil, sourceRef: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.threadId = threadId
        self.title = title
        self.dueAt = dueAt
        self.dueHasTime = dueHasTime
        self.estimateMin = estimateMin
        self.status = status
        self.completedAt = completedAt
        self.completionSource = completionSource
        self.source = source
        self.sourceRef = sourceRef
        self.createdAt = createdAt
    }
}

/// 서버 PlanBlock.
public struct PlanBlockDTO: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var todoId: UUID?
    public var threadId: UUID?
    public var startAt: Date
    public var endAt: Date
    public var locked: Bool
    public var origin: BlockOrigin
    public var status: BlockStatus

    public init(id: UUID = UUID(), todoId: UUID? = nil, threadId: UUID? = nil, startAt: Date = Date(), endAt: Date = Date(), locked: Bool = false, origin: BlockOrigin = .user, status: BlockStatus = .planned) {
        self.id = id
        self.todoId = todoId
        self.threadId = threadId
        self.startAt = startAt
        self.endAt = endAt
        self.locked = locked
        self.origin = origin
        self.status = status
    }
}

/// 서버 Crew.
public struct CrewDTO: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var inviteCode: String
    public var memberCount: Int
    public var role: String

    public init(id: UUID = UUID(), name: String = "", inviteCode: String = "", memberCount: Int = 0, role: String = "") {
        self.id = id
        self.name = name
        self.inviteCode = inviteCode
        self.memberCount = memberCount
        self.role = role
    }
}

/// 서버 Comment.
public struct CommentDTO: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var author: ProfileCard
    public var body: String
    public var createdAt: Date

    public init(id: UUID = UUID(), author: ProfileCard = ProfileCard(), body: String = "", createdAt: Date = Date()) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }
}

/// 서버 FeedCard. 개인 제목·할 일·예정 시간은 들어 있지 않다.
public struct FeedCardDTO: Identifiable, Hashable, Codable, Sendable {
    public var sessionId: UUID
    public var author: ProfileCard
    public var threadId: UUID?
    public var shareTitle: String?
    public var primaryCategory: ActivityCategory
    public var startedAt: Date
    public var endedAt: Date?
    public var status: SessionStatus
    public var durationSeconds: Int
    public var progressNote: String?
    public var photoPath: String?
    public var photoThumbPath: String?
    public var captureMode: CaptureMode
    public var endCorrected: Bool
    public var offlineStarted: Bool
    public var joinedWith: ProfileCard?
    public var reactionCount: Int
    public var myReaction: String?
    public var commentCount: Int
    /// 크루에게 공개한 기록이면 그 크루의 id와 이름.
    public var groupId: UUID?
    public var groupName: String?

    public init(sessionId: UUID = UUID(), author: ProfileCard = ProfileCard(), threadId: UUID? = nil, shareTitle: String? = nil, primaryCategory: ActivityCategory = .study, startedAt: Date = Date(), endedAt: Date? = nil, status: SessionStatus = .live, durationSeconds: Int = 0, progressNote: String? = nil, photoPath: String? = nil, photoThumbPath: String? = nil, captureMode: CaptureMode = .noPhoto, endCorrected: Bool = false, offlineStarted: Bool = false, joinedWith: ProfileCard? = nil, reactionCount: Int = 0, myReaction: String? = nil, commentCount: Int = 0, groupId: UUID? = nil, groupName: String? = nil) {
        self.sessionId = sessionId
        self.author = author
        self.threadId = threadId
        self.shareTitle = shareTitle
        self.primaryCategory = primaryCategory
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.durationSeconds = durationSeconds
        self.progressNote = progressNote
        self.photoPath = photoPath
        self.photoThumbPath = photoThumbPath
        self.captureMode = captureMode
        self.endCorrected = endCorrected
        self.offlineStarted = offlineStarted
        self.joinedWith = joinedWith
        self.reactionCount = reactionCount
        self.myReaction = myReaction
        self.commentCount = commentCount
        self.groupId = groupId
        self.groupName = groupName
    }

    public var id: UUID { sessionId }

    /// 화면에 보일 제목. 공유 제목이 없거나 비었으면 분야 이름으로 채운다(계약 보정 R8).
    public var displayTitle: String {
        if let title = shareTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return primaryCategory.displayName
    }
    public var isLive: Bool { status == .live || status == .paused }
    public var recordBadges: [String] {
        RecordBadge.labels(captureMode: captureMode, endCorrected: endCorrected, offlineStarted: offlineStarted)
    }
}

/// list_crew_members의 한 행 (ProfileCard 필드 + role).
public struct CrewMemberDTO: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var handle: String
    public var displayName: String
    public var avatarPath: String?
    public var departmentName: String?
    public var role: String

    public init(id: UUID = UUID(), handle: String = "", displayName: String = "", avatarPath: String? = nil, departmentName: String? = nil, role: String = "") {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarPath = avatarPath
        self.departmentName = departmentName
        self.role = role
    }
}

/// list_friend_requests의 응답.
public struct FriendRequestsDTO: Hashable, Codable, Sendable {
    public var incoming: [ProfileCard]
    public var outgoing: [ProfileCard]

    public init(incoming: [ProfileCard] = [], outgoing: [ProfileCard] = []) {
        self.incoming = incoming
        self.outgoing = outgoing
    }
}
