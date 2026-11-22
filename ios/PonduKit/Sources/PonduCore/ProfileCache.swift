import Foundation
import SwiftData

@Model
final class CachedProfileRecord {
    @Attribute(.unique) var key: String
    var userID: String
    var json: Data
    var savedAt: Date

    init(key: String, userID: String, json: Data, savedAt: Date) {
        self.key = key
        self.userID = userID
        self.json = json
        self.savedAt = savedAt
    }
}

/// 내 프로필의 기기 저장분(SwiftData). 앱을 켜면 이것으로 먼저 화면을 그린 뒤 서버 값으로 갱신한다.
/// 저장소 이름을 따로 붙여서 다른 기능이 만드는 SwiftData 저장소와 부딪히지 않는다.
public final class ProfileCache: @unchecked Sendable {
    private let container: ModelContainer?
    private let lock = NSLock()
    private static let recordKey = "me"

    /// - Parameter inMemory: 테스트·미리보기에서 true.
    public init(inMemory: Bool = false) {
        let configuration = ModelConfiguration("pondu-profile", schema: Schema([CachedProfileRecord.self]), isStoredInMemoryOnly: inMemory)
        self.container = try? ModelContainer(for: Schema([CachedProfileRecord.self]), configurations: configuration)
    }

    /// 저장된 내 프로필. `userID`가 주어지면 같은 사용자 것일 때만 돌려준다.
    public func load(userID: UUID? = nil) -> Profile? {
        lock.lock()
        defer { lock.unlock() }
        guard let container else { return nil }
        let context = ModelContext(container)
        guard let record = (try? context.fetch(FetchDescriptor<CachedProfileRecord>()))?.first(where: { $0.key == Self.recordKey }),
              let profile = try? PonduJSON.makeDecoder().decode(Profile.self, from: record.json) else { return nil }
        if let userID, profile.id != userID { return nil }
        return profile
    }

    public func save(_ profile: Profile) {
        lock.lock()
        defer { lock.unlock() }
        guard let container, let json = try? PonduJSON.makeEncoder().encode(profile) else { return }
        let context = ModelContext(container)
        if let existing = (try? context.fetch(FetchDescriptor<CachedProfileRecord>()))?.first(where: { $0.key == Self.recordKey }) {
            existing.userID = profile.id.uuidString
            existing.json = json
            existing.savedAt = Date()
        } else {
            context.insert(CachedProfileRecord(key: Self.recordKey, userID: profile.id.uuidString, json: json, savedAt: Date()))
        }
        try? context.save()
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        guard let container else { return }
        let context = ModelContext(container)
        for record in (try? context.fetch(FetchDescriptor<CachedProfileRecord>())) ?? [] {
            context.delete(record)
        }
        try? context.save()
    }
}
