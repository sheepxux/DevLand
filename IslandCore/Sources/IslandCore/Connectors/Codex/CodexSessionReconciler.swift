import Foundation

/// Combines passive observations with the live Hook channel. A log record is
/// never an approval request and cannot dismiss a real pending decision.
enum CodexSessionReconciler {
    static func reconcile(
        hooks: [AgentTask],
        observations: [CodexSessionObservation],
        pendingTasks: [AgentTask] = [],
        endedSessions: [String: Date] = [:]
    ) -> [AgentTask] {
        var result = Dictionary(
            StateReconciler.normalizedSnapshot(hooks, source: "codex")
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for observation in observations {
            let observed = observation.task
            guard observed.source == "codex",
                  observed.status != .waiting,
                  LocalAgentEvent.validSessionId(observed.id) != nil,
                  endedSessions[observed.id].map({ observed.updatedAt > $0 }) ?? true
            else { continue }
            if let hook = result[observed.id] {
                var merged = observed.updatedAt > hook.updatedAt ? observed : hook
                // Hooks retain the reliable terminal jump target; session
                // logs provide a human label even while a Hook owns status.
                merged.jumpContext = hook.jumpContext ?? observed.jumpContext
                merged.title = observed.title
                result[observed.id] = merged
            } else {
                result[observed.id] = observed
            }
        }
        for task in pendingTasks where task.source == "codex" {
            var protected = task
            if let label = result[task.id]?.title { protected.title = label }
            result[task.id] = protected
        }
        return result.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
    }
}
