import Foundation
import IslandCore

/// Copy for the "connected but not reporting" state: the vendor is working,
/// the island is blank, and the user needs one concrete next step.
struct LocalAgentReportingNotice: Equatable {
    let source: String
    let title: String
    let hint: String

    var accessibilityLabel: String { "\(title) \(hint)" }
}

enum LocalAgentReportingPresentation {
    /// The first Agent that is not reporting, Codex first because its trust
    /// gate is the common cause. `nil` when every connected Agent is fine.
    static func notice(
        _ snapshot: LocalAgentReportingSnapshot?,
        language: DevIslandLanguage = .current
    ) -> LocalAgentReportingNotice? {
        guard let snapshot else { return nil }
        let candidates = snapshot.notReporting.sorted { lhs, rhs in
            if lhs.source == "codex" { return true }
            if rhs.source == "codex" { return false }
            return lhs.displayName < rhs.displayName
        }
        guard let agent = candidates.first else { return nil }
        return LocalAgentReportingNotice(
            source: agent.source,
            title: L10n.format(
                "%@ is running but not reporting to the island.",
                language: language,
                agent.displayName
            ),
            hint: hint(for: agent, language: language)
        )
    }

    static func hint(
        for agent: LocalAgentReportingHealth,
        language: DevIslandLanguage
    ) -> String {
        if let reviewCommand = LocalAgentRegistry.descriptor(for: agent.source)?.hookActivationRequirement.reviewCommand {
            return L10n.format(
                "Open %@ and run %@ to trust the Dev Island hooks.",
                language: language,
                agent.displayName,
                reviewCommand
            )
        }
        return L10n.string("Update its hook in Settings › Agents.", language: language)
    }
}
