import Foundation

/// Decides when the monitor must read the logs again without a filesystem
/// change: only when a visible row is due to age out, or when the previous
/// pass had to defer reads because its byte budget ran out. Everything else
/// waits for an event, so an idle Codex costs no wakeups at all.
enum CodexSessionMonitorSchedule {
    /// A running observation is hidden after this long without an event.
    static let runningRetention: TimeInterval = 30 * 60
    /// A finished or interrupted response stays visible this long.
    static let endedRetention: TimeInterval = 2 * 60 * 60
    /// The shortest wait between two passes, so a clock slightly ahead of an
    /// expiry can never spin the loop.
    static let minimumDelay: TimeInterval = 1.0

    static func nextDeadline(
        for observations: [CodexSessionObservation],
        hasDeferredReads: Bool,
        now: Date
    ) -> Date? {
        let floor = now.addingTimeInterval(minimumDelay)
        if hasDeferredReads { return floor }
        let expiries = observations.map { observation -> Date in
            observation.task.updatedAt.addingTimeInterval(retention(for: observation.task.status))
        }
        guard let earliest = expiries.min() else { return nil }
        return max(earliest, floor)
    }

    static func retention(for status: TaskStatus) -> TimeInterval {
        status == .running ? runningRetention : endedRetention
    }
}
