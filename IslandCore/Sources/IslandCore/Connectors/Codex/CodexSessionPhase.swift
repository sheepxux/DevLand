import Foundation

/// Stable, non-localized markers the transcript parser stores in
/// `AgentTask.currentPhase` for passive Codex rows. The app maps them to
/// localized copy; no surface shows them verbatim.
public enum CodexSessionPhase {
    public static let responseFinished = "codex.response.finished"
    /// The user stopped the response themselves (`turn_aborted`). Shown as
    /// interrupted, never announced as a failure.
    public static let interrupted = "codex.response.interrupted"
    public static let responseFailed = "codex.response.failed"

    public static func isInterruption(_ phase: String?) -> Bool {
        phase == interrupted
    }
}
