import AppKit
import IslandCore

/// The one-time Codex trust step, reduced to a single action.
///
/// Codex trusts a Hook by the hash of its definition, so it must be reviewed
/// once in the Codex client with the `/hooks` command. Dev Island never types
/// into, launches a thread in, or changes trust inside Codex; it only opens
/// the app and puts the command on the pasteboard so the user can paste it.
enum CodexTrustGuidance {
    static let bundleIdentifier = "com.openai.codex"

    /// The exact entries Codex will list, derived from the registry so the
    /// copy can never drift from what the installer wrote.
    static func entryNames(descriptor: LocalAgentDescriptor = .codex) -> [String] {
        descriptor.hookEvents
    }

    static func reviewCommand(descriptor: LocalAgentDescriptor = .codex) -> String? {
        descriptor.hookActivationRequirement.reviewCommand
    }

    static var isCodexInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    static func summary(language: DevIslandLanguage = .current) -> String {
        L10n.format(
            "Codex trusts a hook once. Open Codex, run %@, and trust these %lld Dev Island entries:",
            language: language,
            reviewCommand() ?? "/hooks",
            Int64(entryNames().count)
        )
    }

    static func actionTitle(language: DevIslandLanguage = .current) -> String {
        L10n.format("Open Codex and copy %@", language: language, reviewCommand() ?? "/hooks")
    }

    /// Copy the review command and bring Codex forward. Returns `false` when
    /// Codex is not installed; the pasteboard is still filled so the user
    /// can paste after installing.
    @discardableResult
    static func openCodexAndCopyReviewCommand(pasteboard: NSPasteboard = .general) -> Bool {
        guard let command = reviewCommand() else { return false }
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
