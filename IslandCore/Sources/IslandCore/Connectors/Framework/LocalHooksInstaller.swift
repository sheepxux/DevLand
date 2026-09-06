import Foundation

/// Installs / removes the Dev Island hook entries for any registered local
/// agent, driven entirely by its `LocalAgentDescriptor`.
///
/// Every vendor line is the same fixed shape, so a definition the user has
/// reviewed (Codex trusts a Hook by the hash of its complete definition)
/// never changes between Dev Island versions:
///
///     "${HOME}/Library/Application Support/island-app/bin/dev-island-hook" \
///         --route /hooks/<source> --event <Event> --port 7824 || true
///
/// The launcher (`LocalHookLauncher`, rendered by `launcherScript`) forwards
/// the JSON payload an agent pipes on stdin to `LocalHookServer`. Lifecycle
/// hooks are fire-and-forget (`-m 2`, output discarded). Verified action hooks
/// remain synchronous long enough for a decision and preserve the server's
/// stdout JSON for the agent.
///
/// Every line ends in `|| true`: if Dev Island is not running, or the launcher
/// is missing, the vendor sees no decision and falls back to its normal
/// approval UI instead of failing or blocking the turn.
///
/// The fixed protocol Header lives in the launcher, and the per-listener random
/// authorization value is read by curl from a current-user private Header
/// file, so neither configuration nor argv becomes a bearer credential.
///
/// JSON surgery is delegated to `HookConfigEditor`: existing user hooks and
/// unknown config keys are preserved, and our entries are recognized by the
/// `/hooks/<source>` route inside the command string, making install
/// idempotent and uninstall surgical — for launcher lines and for the legacy
/// inline curl lines they replace.
public struct LocalHooksInstaller: Sendable {

    /// The port `LocalHookServer` binds on 127.0.0.1.
    public static let defaultPort = 7824

    /// Every state-changing loopback Hook request must carry this exact
    /// non-simple header. It is not a same-user authentication secret; its
    /// purpose is to force browser fetches through CORS preflight and to make
    /// ordinary HTML form POSTs fail closed at the listener.
    static let requestHeaderName = "X-Dev-Island-Hook"
    static let requestHeaderValue = "v1"

    public let descriptor: LocalAgentDescriptor

    public init(_ descriptor: LocalAgentDescriptor) {
        self.descriptor = descriptor
    }

    /// The lifecycle line for this agent's first passive event. Vendor
    /// wrappers and tests use it as the representative managed command.
    public func hookCommand(port: Int = Self.defaultPort) -> String {
        let event = descriptor.hookEvents.first { !descriptor.actionHookEvents.contains($0) }
            ?? descriptor.hookEvents.first
            ?? "SessionStart"
        return hookCommand(for: event, port: port)
    }

    /// One fixed line per event. Only the route, the event name and the port
    /// vary, and all three are stable contract constants; everything the
    /// listener needs at runtime lives in the launcher.
    public func hookCommand(for event: String, port: Int = Self.defaultPort) -> String {
        "\(LocalHookLauncher.shellPath) --route \(descriptor.endpointPath) --event \(event) --port \(port) || true"
    }

    /// Curl reads the random credential from a private header file. The value
    /// therefore never enters Agent configuration or the process argument
    /// list, while a missing/stale file preserves the existing fail-open turn.
    static let requestAuthorizationHeader =
        "-H \"@\(LocalHookAuthorizationStore.shellHeaderFilePath)\" "

    /// Installed = every event we need carries our command.
    public func isInstalled(configURL: URL? = nil) -> Bool {
        let url = configURL ?? descriptor.configURL
        if case .standaloneJavaScriptPlugin = descriptor.hookEntryStyle {
            return StandalonePluginFileEditor.isInstalled(
                at: url,
                expected: standalonePluginData(),
                marker: standalonePluginMarker
            )
        }
        if case .tomlArrayOfTables = descriptor.hookEntryStyle {
            return TomlHookConfigEditor.isInstalled(
                at: url,
                definitions: tomlDefinitions(),
                marker: descriptor.endpointPath
            )
        }
        let requiredRootValues: [String: Any]
        if case .flatVersioned = descriptor.hookEntryStyle {
            requiredRootValues = ["version": 1]
        } else {
            requiredRootValues = [:]
        }
        let commands = Dictionary(uniqueKeysWithValues: descriptor.hookEvents.map { event in
            (event, hookCommand(for: event))
        })
        let handlerTimeouts = Dictionary(uniqueKeysWithValues: descriptor.actionHookEvents.map {
            ($0, descriptor.actionHookTimeoutUnit.encoded(
                seconds: Int(AgentActionRequest.defaultTimeout) + 10
            ))
        })
        let statusMessages = Dictionary(uniqueKeysWithValues: descriptor.actionHookEvents.map {
            ($0, "Waiting for Dev Island")
        })
        return HookConfigEditor.isInstalled(
            at: url,
            commandsByEvent: commands,
            matchersByEvent: descriptor.hookMatchersByEvent,
            handlerTimeoutsByEvent: handlerTimeouts,
            handlerStatusMessagesByEvent: statusMessages,
            requiredRootValues: requiredRootValues,
            marker: descriptor.endpointPath
        )
    }

    /// True when Dev Island owns entries in this config, but they no longer
    /// match the current command set (for example, an older passive approval
    /// hook that needs the verified synchronous response command).
    public func requiresUpdate(configURL: URL? = nil) -> Bool {
        let url = configURL ?? descriptor.configURL
        return hasManagedEntries(configURL: url) && !isInstalled(configURL: url)
    }

    /// Any Dev Island endpoint marker, including a stale command version or
    /// an entry inside a malformed file. Used by bulk maintenance so Settings
    /// never declares "all disconnected" while a managed Hook remains.
    public func hasManagedEntries(configURL: URL? = nil) -> Bool {
        let url = configURL ?? descriptor.configURL
        if case .standaloneJavaScriptPlugin = descriptor.hookEntryStyle {
            return StandalonePluginFileEditor.containsManagedEntries(
                at: url,
                marker: standalonePluginMarker
            )
        }
        if case .tomlArrayOfTables = descriptor.hookEntryStyle {
            return TomlHookConfigEditor.containsManagedEntries(
                at: url,
                marker: descriptor.endpointPath
            )
        }
        return HookConfigEditor.containsManagedEntries(at: url, marker: descriptor.endpointPath)
    }

    /// A production install (no explicit `configURL`) first makes sure the
    /// launcher every line points at is present and current. Tests and
    /// fixtures pass their own config URL and manage the launcher themselves.
    public func install(configURL: URL? = nil, port: Int = Self.defaultPort) throws {
        if configURL == nil {
            try LocalHookLauncher.ensureInstalled()
        }
        let url = configURL ?? descriptor.configURL
        if case .standaloneJavaScriptPlugin = descriptor.hookEntryStyle {
            try StandalonePluginFileEditor.install(
                at: url,
                expected: standalonePluginData(port: port),
                marker: standalonePluginMarker
            )
            return
        }
        if case .tomlArrayOfTables = descriptor.hookEntryStyle {
            try TomlHookConfigEditor.install(
                at: url,
                definitions: tomlDefinitions(port: port),
                marker: descriptor.endpointPath
            )
            return
        }
        var rootDefaults: [String: Any] = [:]
        if case .flatVersioned = descriptor.hookEntryStyle {
            rootDefaults = ["version": 1]
        }

        let groupsByEvent = Dictionary(uniqueKeysWithValues: descriptor.hookEvents.map { event in
            (event, hookGroup(for: event, port: port))
        })

        try HookConfigEditor.install(
            at: url,
            groupsByEvent: groupsByEvent,
            marker: descriptor.endpointPath,
            rootDefaults: rootDefaults
        )
    }

    public func uninstall(configURL: URL? = nil) throws {
        let url = configURL ?? descriptor.configURL
        if case .standaloneJavaScriptPlugin = descriptor.hookEntryStyle {
            try StandalonePluginFileEditor.uninstall(
                at: url,
                marker: standalonePluginMarker
            )
        } else if case .tomlArrayOfTables = descriptor.hookEntryStyle {
            try TomlHookConfigEditor.uninstall(at: url, marker: descriptor.endpointPath)
        } else {
            try HookConfigEditor.uninstall(at: url, marker: descriptor.endpointPath)
        }
    }

    /// Build uninstall bytes without writing. Disconnect All uses this common
    /// entry point so JSON and TOML configs participate in the same
    /// prepare-first, compare-before-write, rollback-safe transaction.
    func preparedUninstall(
        from data: Data,
        at url: URL
    ) throws -> PreparedHookUninstall {
        if case .standaloneJavaScriptPlugin = descriptor.hookEntryStyle {
            return try StandalonePluginFileEditor.shouldRemoveManagedFile(
                from: data,
                at: url,
                marker: standalonePluginMarker
            ) ? .removeFile : .unchanged
        }
        if case .tomlArrayOfTables = descriptor.hookEntryStyle {
            return try TomlHookConfigEditor.preparedUninstall(
                from: data,
                at: url,
                marker: descriptor.endpointPath
            ).map(PreparedHookUninstall.replace) ?? .unchanged
        }
        return try HookConfigEditor.preparedUninstall(
            from: data,
            at: url,
            marker: descriptor.endpointPath
        ).map(PreparedHookUninstall.replace) ?? .unchanged
    }

    private func hookGroup(for event: String, port: Int) -> [String: Any] {
        let command = hookCommand(for: event, port: port)
        switch descriptor.hookEntryStyle {
        case .nestedWithEmptyMatcher:
            var handler: [String: Any] = ["type": "command", "command": command]
            if descriptor.actionHookEvents.contains(event) {
                handler["timeout"] = descriptor.actionHookTimeoutUnit.encoded(
                    seconds: Int(AgentActionRequest.defaultTimeout) + 10
                )
                handler["statusMessage"] = "Waiting for Dev Island"
            }
            return [
                "matcher": descriptor.hookMatchersByEvent[event] ?? "",
                "hooks": [handler],
            ]
        case .nested:
            var handler: [String: Any] = ["type": "command", "command": command]
            if descriptor.actionHookEvents.contains(event) {
                handler["timeout"] = descriptor.actionHookTimeoutUnit.encoded(
                    seconds: Int(AgentActionRequest.defaultTimeout) + 10
                )
                handler["statusMessage"] = "Waiting for Dev Island"
            }
            return ["hooks": [handler]]
        case .flatVersioned:
            return ["command": command]
        case .tomlArrayOfTables:
            preconditionFailure("TOML Hooks are rendered by TomlHookConfigEditor")
        case .standaloneJavaScriptPlugin:
            preconditionFailure("Standalone plugins are rendered by their descriptor")
        }
    }

    private func tomlDefinitions(port: Int = Self.defaultPort) -> [TomlHookDefinition] {
        descriptor.hookEvents.map { event in
            TomlHookDefinition(
                event: event,
                matcher: descriptor.hookMatchersByEvent[event],
                command: hookCommand(for: event, port: port),
                timeout: 5
            )
        }
    }

    private var standalonePluginMarker: String {
        "Dev Island managed local plugin: \(descriptor.source)"
    }

    private func standalonePluginData(port: Int = Self.defaultPort) -> Data {
        guard let renderer = descriptor.standalonePluginRenderer else {
            preconditionFailure("Standalone plugin renderer is missing")
        }
        return renderer(port)
    }
}

// MARK: - Launcher template

extension LocalHooksInstaller {
    /// Seconds a verified action Hook may wait for the island's decision.
    static let launcherActionTimeoutSeconds = Int(AgentActionRequest.defaultTimeout) + 5
    /// Seconds a lifecycle Hook may spend before it is abandoned fail-open.
    static let launcherPassiveTimeoutSeconds = 2

    /// The launcher is a static `sh` program: no template variables, so its
    /// bytes — and the vendor line that points at it — never change between
    /// Dev Island versions. Only the registry decides which route/event pairs
    /// wait for a decision and which routes carry terminal hints.
    static func launcherScript(registry: [LocalAgentDescriptor] = LocalAgentRegistry.all) -> String {
        let commandDescriptors = registry.filter { $0.standalonePluginRenderer == nil }
        let actionPatterns = commandDescriptors.flatMap { descriptor in
            descriptor.actionHookEvents.sorted().map { "\(descriptor.endpointPath)/\($0)" }
        }.sorted()
        let plainRoutes = commandDescriptors
            .filter { !$0.usesTerminalFallback }
            .map(\.endpointPath)
            .sorted()
        let actionCase = actionPatterns.isEmpty ? "''" : actionPatterns.joined(separator: "|")
        let plainCase = plainRoutes.isEmpty ? "''" : plainRoutes.joined(separator: "|")
        let terminalHeaders = "-H \"X-Dev-Island-Terminal-Bundle: ${__CFBundleIdentifier:-}\" "
            + "-H \"X-Dev-Island-Terminal-Program: ${TERM_PROGRAM:-}\" "
            + "-H \"X-Dev-Island-TTY: $(/bin/ps -o tty= -p $$ | /usr/bin/tr -d '[:space:]')\" "
            + "-H \"X-Dev-Island-Tmux: ${TMUX:-}\" "
            + "-H \"X-Dev-Island-Tmux-Pane: ${TMUX_PANE:-}\" "
        let commonHeaders = "-H 'Content-Type: application/json' "
            + "-H '\(requestHeaderName): \(requestHeaderValue)' "
            + requestAuthorizationHeader
        return """
        #!/bin/sh
        # Dev Island local Hook launcher. Managed by Dev Island; do not edit.
        # Forwards the Agent's JSON from stdin to the loopback listener. Fail-open:
        # a stopped or missing Dev Island never fails the Agent's turn.
        ROUTE=""; EVENT=""; PORT=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --route) ROUTE="$2"; shift 2 ;;
            --event) EVENT="$2"; shift 2 ;;
            --port) PORT="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        case "$ROUTE" in /hooks/) exit 0 ;; /hooks/*[!a-z0-9-]*) exit 0 ;; /hooks/*) ;; *) exit 0 ;; esac
        case "$EVENT" in ""|*[!A-Za-z0-9_-]*) exit 0 ;; esac
        case "$PORT" in ""|*[!0-9]*) exit 0 ;; esac
        MODE=passive
        case "$ROUTE/$EVENT" in \(actionCase)) MODE=action ;; esac
        TERMINAL=1
        case "$ROUTE" in \(plainCase)) TERMINAL=0 ;; esac
        send() {
          if [ "$TERMINAL" = 1 ]; then
            /usr/bin/curl --noproxy 127.0.0.1 -sf -m "$1" -X POST "http://127.0.0.1:${PORT}${ROUTE}" \(commonHeaders)\(terminalHeaders)--data-binary @-
          else
            /usr/bin/curl --noproxy 127.0.0.1 -sf -m "$1" -X POST "http://127.0.0.1:${PORT}${ROUTE}" \(commonHeaders)--data-binary @-
          fi
        }
        if [ "$MODE" = action ]; then
          send \(launcherActionTimeoutSeconds) 2>/dev/null || true
        else
          send \(launcherPassiveTimeoutSeconds) >/dev/null 2>&1 || true
        fi
        exit 0

        """
    }
}

enum PreparedHookUninstall {
    case unchanged
    case replace(Data)
    case removeFile
}
