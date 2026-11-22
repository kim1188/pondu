import Foundation

/// 경과 시간 계산. 기기 시계(Date)는 쓰지 않고, 서버가 준 값을 받은 순간의 단조 시계(잠자는 동안도 흐름)로 이어 센다.
/// 기기 시각을 바꿔도 값이 달라지지 않는다.
struct SessionClock: Equatable {
    /// 앵커 시점의 경과 초
    var base: TimeInterval
    /// 앵커를 잡은 순간의 단조 시계 값(초)
    var anchorUptime: TimeInterval
    var running: Bool

    static func monotonicNow() -> TimeInterval {
        #if canImport(Darwin)
        return TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
        #else
        return ProcessInfo.processInfo.systemUptime
        #endif
    }

    /// 방금 누른 시작처럼 서버 응답 전의 임시 시계. 0에서 시작.
    static func provisional(uptime: TimeInterval = SessionClock.monotonicNow()) -> SessionClock {
        SessionClock(base: 0, anchorUptime: uptime, running: true)
    }

    /// 서버가 준 started_at, paused_at, paused_seconds로 계산한 경과 초(정지 중이면 정지 시각까지).
    static func formula(startedAt: Date, pausedAt: Date?, pausedSeconds: Double, now: Date) -> TimeInterval {
        let end = pausedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - pausedSeconds)
    }

    /// 서버 세션을 받은 순간 앵커를 잡는다. 진행 중이면 서버가 계산한 duration_seconds(=지금까지)에서 이어 센다.
    init(snapshot s: SessionSnapshot, uptime: TimeInterval = SessionClock.monotonicNow()) {
        switch s.phase {
        case .live:
            self.init(base: max(0, s.durationSeconds), anchorUptime: uptime, running: true)
        case .paused:
            let frozen: TimeInterval
            if let pausedAt = s.pausedAt {
                frozen = SessionClock.formula(startedAt: s.startedAt, pausedAt: pausedAt, pausedSeconds: s.pausedSeconds, now: pausedAt)
            } else {
                frozen = max(0, s.durationSeconds)
            }
            self.init(base: frozen, anchorUptime: uptime, running: false)
        case .ended, .needsConfirmation:
            self.init(base: max(0, s.durationSeconds), anchorUptime: uptime, running: false)
        }
    }

    init(base: TimeInterval, anchorUptime: TimeInterval, running: Bool) {
        self.base = base
        self.anchorUptime = anchorUptime
        self.running = running
    }

    func elapsed(at uptime: TimeInterval = SessionClock.monotonicNow()) -> TimeInterval {
        max(0, base + (running ? max(0, uptime - anchorUptime) : 0))
    }

    func paused(at uptime: TimeInterval = SessionClock.monotonicNow()) -> SessionClock {
        SessionClock(base: elapsed(at: uptime), anchorUptime: uptime, running: false)
    }

    func resumed(at uptime: TimeInterval = SessionClock.monotonicNow()) -> SessionClock {
        SessionClock(base: base, anchorUptime: uptime, running: true)
    }
}

enum ElapsedFormat {
    /// 0:07, 37:05, 1:02:09
    static func clock(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
