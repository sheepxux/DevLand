import IslandCore

enum CodexSessionMonitoringPresentation {
    /// Terminal log events close one response, not the user's overall goal.
    /// A genuine failure and a user interruption both end as `.failed`; the
    /// phase marker tells them apart.
    static func responseStatus(
        _ status: TaskStatus,
        phase: String? = nil,
        language: DevIslandLanguage = .current
    ) -> String? {
        switch status {
        case .completed: return L10n.string("Response finished", language: language)
        case .failed:
            let key = phase == CodexSessionPhase.responseFailed ? "Response failed" : "Response interrupted"
            return L10n.string(key, language: language)
        case .running, .waiting: return nil
        }
    }

    /// Phase text that is safe on any surface: passive Codex markers become
    /// localized copy, other Agents' phases pass through unchanged.
    static func displayPhase(
        for task: AgentTask,
        language: DevIslandLanguage = .current
    ) -> String? {
        if task.source == "codex",
           let response = responseStatus(task.status, phase: task.currentPhase, language: language) {
            return response
        }
        return task.currentPhase
    }

    static func status(
        _ status: CodexSessionMonitorStatus,
        language: DevIslandLanguage = .current
    ) -> String {
        let key: String
        switch status {
        case .stopped: key = "Session monitoring is off"
        case .notFound: key = "Waiting for a local Codex session"
        case .available: key = "Monitoring local Codex activity"
        case .unavailable: key = "Local Codex sessions could not be read"
        }
        return L10n.string(key, language: language)
    }
}
