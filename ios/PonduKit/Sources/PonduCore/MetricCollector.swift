import Foundation
import os
#if canImport(MetricKit)
import MetricKit
#endif

/// MetricKit으로 실행 시간·멈춤·메모리를 모은다. 첫 화면이 뜬 뒤에 `start()`를 부른다(SRD 4.2절).
/// 받은 보고서는 기기에 JSON으로 보관하고(최근 20건) 시스템 로그에 요약을 남긴다. 서버로 보내지 않는다.
public final class MetricCollector: NSObject, @unchecked Sendable {
    public static let shared = MetricCollector()

    private let logger = Logger(subsystem: Signpost.subsystem, category: "metrics")
    private let maxFiles = 20
    private var started = false

    public var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Metrics", isDirectory: true)
    }

    public func start() {
        #if canImport(MetricKit)
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        #endif
    }

    func store(json: Data, kind: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? json.write(to: directory.appendingPathComponent("\(kind)-\(stamp).json"), options: .atomic)
        trim()
    }

    private func trim() {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = urls.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for url in sorted.dropFirst(maxFiles) { try? manager.removeItem(at: url) }
    }
}

#if canImport(MetricKit)
extension MetricCollector: MXMetricManagerSubscriber {
    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            store(json: payload.jsonRepresentation(), kind: "metrics")
            logger.info("metric payload received")
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            store(json: payload.jsonRepresentation(), kind: "diagnostics")
            logger.error("diagnostic payload received (hangs: \(payload.hangDiagnostics?.count ?? 0), crashes: \(payload.crashDiagnostics?.count ?? 0))")
        }
    }
}
#endif
