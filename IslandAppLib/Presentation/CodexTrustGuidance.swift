import AppKit
import IslandCore

/// Copy for explicit hook authorization, with a CLI-only manual fallback.
/// `/hooks` is a Codex CLI command, not a desktop chat message.
enum CodexTrustGuidance {
    /// The exact entries Codex will list, derived from the registry so the
    /// copy can never drift from what the installer wrote.
    static func entryNames(descriptor: LocalAgentDescriptor = .codex) -> [String] {
        descriptor.hookEvents
    }

    static func reviewCommand(descriptor: LocalAgentDescriptor = .codex) -> String? {
        descriptor.hookActivationRequirement.reviewCommand
    }

    static func summary(language: DevIslandLanguage = .current) -> String {
        L10n.string(
            "Task monitoring works independently. To handle approvals in the island, review and authorize the Dev Island hooks.",
            language: language
        )
    }

    static func actionTitle(language: DevIslandLanguage = .current) -> String {
        L10n.string("Review and authorize hooks", language: language)
    }

    static func manualInstructions(language: DevIslandLanguage = .current) -> String {
        L10n.format(
            "For manual setup, paste the launch command in Terminal. Then enter %@ in Codex CLI and trust only Dev Island entries.",
            language: language, reviewCommand() ?? "/hooks"
        )
    }

    /// Quote the verified executable as a single shell argument. No prompt,
    /// permission flag, script, or shell expansion is appended.
    static func launcherCommand(executableURL: URL?) -> String? {
        guard let executableURL, executableURL.isFileURL,
              executableURL.path.hasPrefix("/"),
              !executableURL.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return "'" + executableURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    static func copyCLILaunchCommand(
        pasteboard: NSPasteboard = .general,
        executableURL: URL? = CodexHookAuthorization.verifiedExecutableURL()
    ) -> Bool {
        guard let command = launcherCommand(executableURL: executableURL) else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(command, forType: .string)
    }

    static func errorMessage(_ error: Error, language: DevIslandLanguage = .current) -> String {
        let key: String
        switch error as? CodexHookAuthorizationError {
        case .unavailable:
            key = "The signed Codex app could not be found. Install Codex, then try again."
        case .unsupportedVersion:
            key = "This Codex version needs manual hook review in Codex CLI."
        case .invalidDefinitions:
            key = "Dev Island hooks are missing, disabled, or changed. Update the connection, then review again."
        case .changedSinceReview:
            key = "Hooks or configuration changed during review. Close this review and try again."
        case .verificationFailed:
            key = "Authorization could not be verified. Check the connection before retrying."
        default:
            key = "Codex could not complete this request. Try again or use manual setup."
        }
        return L10n.string(key, language: language)
    }
}
