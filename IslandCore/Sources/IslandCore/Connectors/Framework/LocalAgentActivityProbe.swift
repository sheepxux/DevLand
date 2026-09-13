import Foundation

/// Metadata-only heartbeat for a local Agent: when did the vendor last touch
/// one of its own session files on disk?
///
/// Hooks fail open by design, so a Hook that a vendor has silently stopped
/// running (untrusted in Codex, rewritten by another tool, a stale launcher)
/// leaves the island blank while the Agent works. Comparing the vendor's own
/// on-disk activity with the last Hook event Dev Island received turns that
/// silence into a visible "not reporting" state.
///
/// The probe never opens or reads a session file. It enumerates at most
/// `maximumEnumeratedEntries` directory entries, looks only at file type and
/// modification date, skips symbolic links inside the tree, and resolves a
/// symbolic-link root once before requiring a real directory.
public struct LocalAgentActivityProbe: Sendable {
    public static let maximumEnumeratedEntries = 8_192

    public enum Activity: Equatable, Sendable {
        /// Dev Island does not know where this vendor keeps session activity.
        case unsupported
        /// The vendor's activity roots exist but hold no matching files.
        case none
        /// Newest modification date of a matching session file.
        case active(Date)
    }

    struct Root: Sendable {
        let relativePath: String
        let filePrefix: String
        let fileExtension: String
    }

    /// Where each vendor appends per-session activity. Content is never read.
    static let roots: [String: [Root]] = [
        "codex": [
            Root(relativePath: ".codex/sessions", filePrefix: "rollout-", fileExtension: "jsonl"),
            Root(relativePath: ".codex/archived_sessions", filePrefix: "rollout-", fileExtension: "jsonl"),
        ],
        "claude-code": [
            Root(relativePath: ".claude/projects", filePrefix: "", fileExtension: "jsonl"),
        ],
    ]

    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public static var supportedSources: [String] {
        roots.keys.sorted()
    }

    public func activity(for source: String) -> Activity {
        guard let roots = Self.roots[source] else { return .unsupported }
        var newest: Date?
        var enumeratedEntries = 0
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]

        for root in roots {
            // A symbolic-link root (dotfiles layouts) is resolved exactly once;
            // links inside the tree are never followed.
            let rootURL = homeDirectory
                .appendingPathComponent(root.relativePath, isDirectory: true)
                .resolvingSymlinksInPath()
            guard let rootValues = try? rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  rootValues.isDirectory == true,
                  rootValues.isSymbolicLink != true,
                  let enumerator = manager.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                enumeratedEntries += 1
                guard enumeratedEntries <= Self.maximumEnumeratedEntries else {
                    return newest.map(Activity.active) ?? .none
                }
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isRegularFile == true,
                      url.lastPathComponent.hasPrefix(root.filePrefix),
                      url.pathExtension == root.fileExtension,
                      let modifiedAt = values.contentModificationDate else { continue }
                if newest.map({ modifiedAt > $0 }) ?? true {
                    newest = modifiedAt
                }
            }
        }
        return newest.map(Activity.active) ?? .none
    }
}

/// Whether one connected Agent's Hooks are actually delivering events.
public enum LocalAgentReportingState: String, Equatable, Sendable {
    /// Vendor activity and Hook events both arrived inside the window.
    case reporting
    /// The vendor is writing session activity, nothing reached the island,
    /// and no live session for it is on the island: the Hook is not running.
    case notReporting = "not-reporting"
    /// No recent vendor activity, so there is nothing to compare.
    case idle
    /// Dev Island does not know where this vendor records activity.
    case unknown
}

/// Low-cardinality, privacy-safe reporting health for one connected Agent.
public struct LocalAgentReportingHealth: Equatable, Sendable {
    public let source: String
    public let displayName: String
    public let hookState: LocalAgentHookConnectionState
    public let state: LocalAgentReportingState

    public init(
        source: String,
        displayName: String,
        hookState: LocalAgentHookConnectionState,
        state: LocalAgentReportingState
    ) {
        self.source = source
        self.displayName = displayName
        self.hookState = hookState
        self.state = state
    }
}

public struct LocalAgentReportingSnapshot: Equatable, Sendable {
    public static let defaultActivityWindow: TimeInterval = 120

    public let agents: [LocalAgentReportingHealth]
    public let observedAt: Date

    public init(agents: [LocalAgentReportingHealth], observedAt: Date) {
        self.agents = agents
        self.observedAt = observedAt
    }

    public var notReporting: [LocalAgentReportingHealth] {
        agents.filter { $0.state == .notReporting }
    }

    /// Pure combination rule, kept free of files and actors so it is testable.
    ///
    /// Only connected/configured Agents are judged. A vendor with recent
    /// activity but neither a recent Hook event nor a live island session is
    /// `notReporting`; recent activity with a recent event is `reporting`;
    /// stale or absent activity is `idle`; an unsupported vendor is `unknown`.
    public static func derive(
        hooks: LocalAgentHookHealthSnapshot,
        activity: [String: LocalAgentActivityProbe.Activity],
        lastHookEventAt: [String: Date],
        liveSources: Set<String>,
        now: Date,
        activityWindow: TimeInterval = defaultActivityWindow
    ) -> LocalAgentReportingSnapshot {
        let agents = hooks.agents.compactMap { agent -> LocalAgentReportingHealth? in
            guard agent.state == .connected || agent.state == .configured else { return nil }
            let state: LocalAgentReportingState
            switch activity[agent.source] ?? .unsupported {
            case .unsupported:
                state = .unknown
            case .none:
                state = .idle
            case let .active(modifiedAt):
                let recentActivity = now.timeIntervalSince(modifiedAt) <= activityWindow
                let recentEvent = lastHookEventAt[agent.source]
                    .map { now.timeIntervalSince($0) <= activityWindow } ?? false
                if !recentActivity {
                    state = .idle
                } else if recentEvent || liveSources.contains(agent.source) {
                    state = .reporting
                } else {
                    state = .notReporting
                }
            }
            return LocalAgentReportingHealth(
                source: agent.source,
                displayName: agent.displayName,
                hookState: agent.state,
                state: state
            )
        }
        return LocalAgentReportingSnapshot(agents: agents, observedAt: now)
    }
}
