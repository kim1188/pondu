import Foundation

protocol RecordCaching {
    func load(userKey: String) -> RecordSnapshot?
    func save(_ snapshot: RecordSnapshot, userKey: String)
}

final class InMemoryRecordCache: RecordCaching {
    private var store: [String: RecordSnapshot] = [:]
    func load(userKey: String) -> RecordSnapshot? { store[userKey] }
    func save(_ snapshot: RecordSnapshot, userKey: String) { store[userKey] = snapshot }
}

/// Caches 폴더에 사용자별 JSON 한 파일. 지워져도 다시 받으면 되는 값이다.
final class FileRecordCache: RecordCaching {
    private let directory: URL
    init(directory: URL? = nil) {
        let base = directory ?? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("PonduRecord", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private func url(_ userKey: String) -> URL { directory.appendingPathComponent("record-\(userKey).json") }

    func load(userKey: String) -> RecordSnapshot? {
        guard let data = try? Data(contentsOf: url(userKey)) else { return nil }
        return try? JSONDecoder().decode(RecordSnapshot.self, from: data)
    }

    func save(_ snapshot: RecordSnapshot, userKey: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url(userKey), options: .atomic)
    }
}
