import Foundation
import IslandCore

/// Settings › Agent groups every local Agent by what the user has to do about
/// it, not by vendor: connected rows need nothing, rows that need attention
/// carry the page's one primary action, everything else offers "Connect".
enum LocalAgentConnectionGroup: Hashable, CaseIterable {
    case connected
    case needsAttention
    case notConnected

    func title(language: DevIslandLanguage) -> String {
        switch self {
        case .connected:      return L10n.string("Connected", language: language)
        case .needsAttention: return L10n.string("Needs action", language: language)
        case .notConnected:   return L10n.string("Not connected", language: language)
        }
    }
}

/// The trailing control a row shows. Exactly one per row; connected rows
/// expand instead of exposing a destructive button.
enum LocalAgentRowAction: Equatable {
    case expand
    case authorize
    case update
    case connect
}

enum LocalAgentRowPresentation {
    /// `nil` while the first diagnostics pass is still running, so rows can
    /// stay in registry order instead of jumping between groups.
    static func group(for state: LocalAgentHookConnectionState?) -> LocalAgentConnectionGroup? {
        switch state {
        case .connected?:      return .connected
        case .configured?:     return .needsAttention
        case .updateRequired?: return .needsAttention
        case .disconnected?:   return .notConnected
        case nil:              return nil
        }
    }

    static func action(for state: LocalAgentHookConnectionState?) -> LocalAgentRowAction {
        switch state {
        case .connected?:      return .expand
        case .configured?:     return .authorize
        case .updateRequired?: return .update
        case .disconnected?, nil: return .connect
        }
    }

    /// Rows inside one group keep the registry order; groups keep the order
    /// the user should read them in.
    static func grouped(
        _ descriptors: [LocalAgentDescriptor],
        states: [String: LocalAgentHookConnectionState]
    ) -> [(group: LocalAgentConnectionGroup?, descriptors: [LocalAgentDescriptor])] {
        guard descriptors.allSatisfy({ states[$0.source] != nil }) else {
            return [(nil, descriptors)]
        }
        return LocalAgentConnectionGroup.allCases.compactMap { group in
            let members = descriptors.filter { self.group(for: states[$0.source]) == group }
            return members.isEmpty ? nil : (group, members)
        }
    }

    /// One human sentence per state. Vendor mechanics (Hooks, trust hashes)
    /// stay out of the sentence; the expanded row explains them on request.
    static func statusLine(
        state: LocalAgentHookConnectionState?,
        descriptor: LocalAgentDescriptor,
        language: DevIslandLanguage
    ) -> String {
        switch state {
        case nil:
            return L10n.string("Checking…", language: language)
        case .disconnected?:
            return L10n.string(
                "Not connected · one step puts its tasks and approvals on the island",
                language: language
            )
        case .updateRequired?:
            return L10n.string(
                "The connection is out of date. Update it to keep approvals on the island.",
                language: language
            )
        case .configured?:
            return L10n.string(
                "Approval hooks are installed. Authorize them to decide in the island.",
                language: language
            )
        case .connected?:
            if descriptor.releaseStage == .preview {
                return L10n.string(
                    "Connected (preview) · requests work in simulation",
                    language: language
                )
            }
            let capabilities = descriptor.capabilities
            if capabilities.permissionRequests == .bidirectional
                || capabilities.questionRequests == .bidirectional
                || capabilities.planReviews == .bidirectional {
                return L10n.string(
                    "Connected · tasks and approvals show on the island",
                    language: language
                )
            }
            if capabilities.permissionRequests == .observeOnly
                || capabilities.questionRequests == .observeOnly
                || capabilities.planReviews == .observeOnly {
                return L10n.string(
                    "Connected · attention requests show on the island",
                    language: language
                )
            }
            return L10n.string(
                "Connected · sessions show on the island",
                language: language
            )
        }
    }

    /// Header line: only the counts that are non-zero, in reading order.
    static func summary(
        connected: Int,
        needsAttention: Int,
        notConnected: Int,
        language: DevIslandLanguage
    ) -> String {
        var parts: [String] = []
        if connected > 0 {
            parts.append(L10n.format("%lld connected", language: language, Int64(connected)))
        }
        if needsAttention > 0 {
            parts.append(L10n.format("%lld need action", language: language, Int64(needsAttention)))
        }
        if notConnected > 0 {
            parts.append(L10n.format("%lld not connected", language: language, Int64(notConnected)))
        }
        if parts.isEmpty {
            return L10n.string("Checking local Agents…", language: language)
        }
        return parts.joined(separator: " · ")
    }

    static func summary(
        _ snapshot: LocalAgentHookHealthSnapshot,
        language: DevIslandLanguage
    ) -> String {
        summary(
            connected: snapshot.connectedCount,
            needsAttention: snapshot.configuredCount + snapshot.updateRequiredCount,
            notConnected: snapshot.disconnectedCount,
            language: language
        )
    }
}
