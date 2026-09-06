import IslandCore

enum CodexSessionMonitoringPresentation {
    /// Terminal log events close one response, not the user's overall goal.
    static func responseStatus(
        _ status: TaskStatus,
        language: DevIslandLanguage = .current
    ) -> String? {
        switch status {
        case .completed: return L10n.string("Response finished", language: language)
        case .failed: return L10n.string("Response interrupted", language: language)
        case .running, .waiting: return nil
        }
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
