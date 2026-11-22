import Foundation
import CryptoKit
import os

/// 값 하나를 잠가서 여러 스레드에서 쓰게 해 주는 작은 상자.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    public func withValue<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value { withValue { $0 } }
}

// MARK: - Debouncer

/// 입력이 멈춘 뒤에만 실행한다(기본 0.3초). 새 입력이 오면 이전 실행은 취소된다.
/// 취소는 `action` 안의 `await`에도 전달되므로 이전 요청이 함께 취소된다.
@MainActor
public final class Debouncer {
    public let delay: TimeInterval
    private var task: Task<Void, Never>?

    public init(delay: TimeInterval = 0.3) {
        self.delay = delay
    }

    public func schedule(_ action: @escaping @MainActor () async -> Void) {
        task?.cancel()
        let delay = self.delay
        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}

// MARK: - InFlight

/// 같은 키로 진행 중인 요청을 하나로 합친다. 먼저 시작한 요청의 결과를 모두가 받는다.
public actor InFlight<Key: Hashable & Sendable, Value: Sendable> {
    private var tasks: [Key: Task<Value, Error>] = [:]

    public init() {}

    public func run(key: Key, _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let existing = tasks[key] {
            return try await existing.value
        }
        let task = Task { try await operation() }
        tasks[key] = task
        defer {
            // 다른 호출이 이미 새 작업으로 바꿔 놓았다면 건드리지 않는다.
            if tasks[key] == task { tasks[key] = nil }
        }
        return try await task.value
    }

    /// 지금 합쳐지고 있는 요청 수(테스트용).
    public var activeCount: Int { tasks.count }
}

// MARK: - DiskCache

/// 키(경로)로 파일을 저장하는 기기 디스크 캐시. 만료 없이 보관하고 용량 상한을 넘으면 오래 안 쓴 것부터 지운다.
public final class DiskCache: @unchecked Sendable {
    public let directory: URL
    public let maxBytes: Int
    private let lock = NSLock()
    private let fileManager = FileManager.default

    public init(directoryName: String = "PonduImages", maxBytes: Int = 200 * 1024 * 1024, baseDirectory: URL? = nil) {
        let base = baseDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = base.appendingPathComponent(directoryName, isDirectory: true)
        self.maxBytes = maxBytes
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func fileURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    public func data(forKey key: String) -> Data? {
        let url = fileURL(forKey: key)
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        // 사용 시각을 갱신해서 오래 안 쓴 순서를 유지한다.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    public func store(_ data: Data, forKey key: String) {
        let url = fileURL(forKey: key)
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        trimLocked()
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var totalBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return entriesLocked().reduce(0) { $0 + $1.size }
    }

    private struct Entry {
        let url: URL
        let size: Int
        let date: Date
    }

    private func entriesLocked() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(url: url, size: values.fileSize ?? 0, date: values.contentModificationDate ?? .distantPast)
        }
    }

    private func trimLocked() {
        var entries = entriesLocked()
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > maxBytes * 9 / 10 {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

// MARK: - Signpost

/// 구간 측정. Instruments의 Points of Interest와 MetricKit 분석에서 보인다.
public enum Signpost {
    public static let subsystem = "kr.pondu.app"
    private static let signposter = OSSignposter(logHandle: OSLog(subsystem: subsystem, category: .pointsOfInterest))

    public struct Interval {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
    }

    public static func begin(_ name: StaticString) -> Interval {
        let id = signposter.makeSignpostID()
        return Interval(name: name, state: signposter.beginInterval(name, id: id))
    }

    public static func end(_ interval: Interval) {
        signposter.endInterval(interval.name, interval.state)
    }

    public static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    /// 동기 구간.
    public static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let interval = begin(name)
        defer { end(interval) }
        return try body()
    }

    /// 비동기 구간.
    public static func measureAsync<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let interval = begin(name)
        defer { end(interval) }
        return try await body()
    }
}

// MARK: - 시간 제한

/// 일반 10초, 비서 20초, 사진 60초(계약 5절).
public enum RequestTimeout {
    public static let standard: TimeInterval = 10
    public static let assistant: TimeInterval = 20
    public static let photo: TimeInterval = 60
}

/// `seconds` 안에 끝나지 않으면 `BackendError.timeout`을 던진다. 바깥에서 취소하면 CancellationError.
public func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                     _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw BackendError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw BackendError.unknown }
        return first
    }
}
