import Foundation

/// Coalesces filesystem change notifications into single wakeups for one
/// consumer and lets that consumer sleep until a change or a deadline,
/// whichever comes first. The monitor loop therefore never wakes on a
/// schedule: with no Codex activity and no live row to expire it sleeps
/// until the next event.
actor CodexSessionChangeSignal {
    enum Wake: Equatable, Sendable {
        case changed
        case deadline
        case cancelled
    }

    private var pending = false
    private var waiter: CheckedContinuation<Wake, Never>?
    private var deadlineTask: Task<Void, Never>?

    /// Record a change. A burst of events collapses into one pending wakeup.
    func signal() {
        guard let waiter else {
            pending = true
            return
        }
        resume(waiter, with: .changed)
    }

    /// Suspend until a change arrives or `deadline` passes. Returns at once
    /// when a change is already pending or the deadline is already due.
    func wait(until deadline: Date?, now: Date = .now) async -> Wake {
        if pending {
            pending = false
            return .changed
        }
        if Task.isCancelled { return .cancelled }
        if let deadline, deadline <= now { return .deadline }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Wake, Never>) in
                waiter = continuation
                guard let deadline else { return }
                let delay = deadline.timeIntervalSince(now)
                deadlineTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay), clock: .continuous)
                    guard !Task.isCancelled else { return }
                    await self?.deadlinePassed()
                }
            }
        } onCancel: {
            Task { await self.cancelWait() }
        }
    }

    private func deadlinePassed() {
        guard let waiter else { return }
        resume(waiter, with: .deadline)
    }

    private func cancelWait() {
        guard let waiter else { return }
        resume(waiter, with: .cancelled)
    }

    private func resume(_ continuation: CheckedContinuation<Wake, Never>, with wake: Wake) {
        waiter = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        continuation.resume(returning: wake)
    }
}
