import Foundation

/// An immutable review obtained from the signed Codex CLI. Only the exact
/// installed Dev Island definitions are eligible for this explicit consent.
public struct CodexHookAuthorizationReview: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let eventName: String
        public let command: String
        let key: String
        let currentHash: String
        let trustStatus: String
    }

    public let entries: [Entry]
    public var isAlreadyAuthorized: Bool { entries.allSatisfy { $0.trustStatus == "trusted" } }
    let configPath: String
    let configVersion: String
    let reviewedAt: Date
}

public enum CodexHookAuthorizationError: Error, Equatable, Sendable {
    case unavailable
    case unsupportedVersion
    case invalidDefinitions
    case changedSinceReview
    case requestFailed
    case verificationFailed
}

/// Uses the same `config/batchWrite` operation as Codex TUI's hooks_rpc.rs.
/// This service never grants consent itself: authorize requires a previously
/// displayed review and must only be called from the user's explicit action.
public struct CodexHookAuthorization: Sendable {
    typealias Transport = @Sendable (_ method: String, _ params: Data) throws -> Data
    private let transport: Transport
    private let hooksPath: String
    private let configPath: String

    public init() {
        transport = { method, params in try Self.invoke(method, params: params) }
        hooksPath = LocalAgentDescriptor.codex.configURL.standardizedFileURL.path
        configPath = LocalAgentDescriptor.codex.configURL.deletingLastPathComponent()
            .appendingPathComponent("config.toml").standardizedFileURL.path
    }

    init(hooksPath: String, configPath: String, transport: @escaping Transport) {
        self.hooksPath = hooksPath
        self.configPath = configPath
        self.transport = transport
    }

    public static func verifiedExecutableURL() -> URL? {
        // The installed Hook channel currently owns the default Codex home.
        // Never authorize that home while monitoring a different runtime.
        let monitoredHome = CodexSessionLogMonitor.defaultRoot.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        let installedHome = LocalAgentDescriptor.codex.configURL.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        guard monitoredHome == installedHome else { return nil }
        return CodexHookTrustProbe.verifiedCodexExecutable()
    }

    public func review() throws -> CodexHookAuthorizationReview {
        try requireSupportedVersion()
        let entries = try readEntries()
        let config = try request("config/read", params: ["includeLayers": true])
        guard let layers = config["layers"] as? [[String: Any]] else {
            throw CodexHookAuthorizationError.requestFailed
        }
        let userLayers = layers.filter {
            guard let name = $0["name"] as? [String: Any] else { return false }
            return name["type"] as? String == "user"
                && name["file"] as? String == configPath
                && (name["profile"] == nil || name["profile"] is NSNull)
                && ($0["disabledReason"] == nil || $0["disabledReason"] is NSNull)
        }
        guard userLayers.count == 1,
              let version = userLayers[0]["version"] as? String,
              Self.isSafeText(version, maximumBytes: 256) else {
            throw CodexHookAuthorizationError.requestFailed
        }
        return CodexHookAuthorizationReview(
            entries: entries, configPath: configPath, configVersion: version, reviewedAt: Date()
        )
    }

    public func authorize(_ review: CodexHookAuthorizationReview) throws {
        guard review.configPath == configPath,
              (0...300).contains(Date().timeIntervalSince(review.reviewedAt)) else {
            throw CodexHookAuthorizationError.changedSinceReview
        }
        let fresh = try self.review()
        guard fresh.entries == review.entries,
              fresh.configVersion == review.configVersion else {
            throw CodexHookAuthorizationError.changedSinceReview
        }
        if fresh.isAlreadyAuthorized { return }

        // Nested Upsert is the vendor's own operation. Keys are opaque JSON
        // object keys, never interpreted as dotted paths or shell fragments.
        let updates = Dictionary(uniqueKeysWithValues: fresh.entries.map {
            ($0.key, ["trusted_hash": $0.currentHash])
        })
        _ = try request("config/batchWrite", params: [
            "edits": [["keyPath": "hooks.state", "value": updates, "mergeStrategy": "upsert"]],
            "filePath": configPath,
            "expectedVersion": fresh.configVersion,
            "reloadUserConfig": true,
        ])

        // A new process re-reads the saved vendor state. A write acknowledgement
        // alone is not evidence that Codex accepted the exact reviewed hooks.
        let verified = try readEntries()
        guard verified.count == fresh.entries.count,
              zip(verified, fresh.entries).allSatisfy({ current, approved in
                  current.key == approved.key && current.currentHash == approved.currentHash
                      && current.command == approved.command && current.eventName == approved.eventName
                      && current.trustStatus == "trusted"
              }) else { throw CodexHookAuthorizationError.verificationFailed }
    }

    private func requireSupportedVersion() throws {
        let version = try transport("--version", Data())
        guard String(data: version, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "codex-cli 0.153.4" else {
            throw CodexHookAuthorizationError.unsupportedVersion
        }
    }

    private func readEntries() throws -> [CodexHookAuthorizationReview.Entry] {
        let descriptor = LocalAgentDescriptor.codex
        let response = try request("hooks/list", params: [
            "cwds": [FileManager.default.homeDirectoryForCurrentUser.path],
        ])
        guard let data = response["data"] as? [[String: Any]], data.count == 1,
              let errors = data[0]["errors"] as? [Any], errors.isEmpty,
              let hooks = data[0]["hooks"] as? [[String: Any]], hooks.count <= 512 else {
            throw CodexHookAuthorizationError.invalidDefinitions
        }
        let ours = hooks.filter {
            $0["sourcePath"] as? String == hooksPath
                && ($0["command"] as? String)?.contains(descriptor.endpointPath) == true
        }
        guard ours.count == descriptor.hookEvents.count else {
            throw CodexHookAuthorizationError.invalidDefinitions
        }
        let installer = LocalHooksInstaller(descriptor)
        var entries: [CodexHookAuthorizationReview.Entry] = []
        for event in descriptor.hookEvents {
            let protocolEvent = event.prefix(1).lowercased() + event.dropFirst()
            let matches = ours.filter { $0["eventName"] as? String == protocolEvent }
            // Version-pinned Codex defaults: ordinary hooks use 600 seconds;
            // SessionEnd is capped to 1 second. The installer sets action
            // hooks to the decision timeout plus its delivery margin.
            let isAction = descriptor.actionHookEvents.contains(event)
            let timeout = isAction ? Int(AgentActionRequest.defaultTimeout) + 10
                : event == "SessionEnd" ? 1 : 600
            guard matches.count == 1, let hook = matches.first,
                  hook["handlerType"] as? String == "command",
                  hook["command"] as? String == installer.hookCommand(for: event),
                  hook["source"] as? String == "user",
                  hook["isManaged"] as? Bool == false,
                  hook["enabled"] as? Bool == true,
                  (hook["async"] == nil || hook["async"] as? Bool == false),
                  hook["timeoutSec"] as? Int == timeout,
                  (hook["additionalContextLimit"] == nil || hook["additionalContextLimit"] is NSNull),
                  (hook["matcher"] == nil || hook["matcher"] is NSNull),
                  (hook["pluginId"] == nil || hook["pluginId"] is NSNull),
                  let key = hook["key"] as? String,
                  key.hasPrefix(hooksPath + ":"), Self.isSafeText(key, maximumBytes: 4_096),
                  let hash = hook["currentHash"] as? String, Self.isVendorHash(hash),
                  let trust = hook["trustStatus"] as? String,
                  ["untrusted", "modified", "trusted"].contains(trust) else {
                throw CodexHookAuthorizationError.invalidDefinitions
            }
            if isAction {
                guard hook["statusMessage"] as? String == "Waiting for Dev Island" else {
                    throw CodexHookAuthorizationError.invalidDefinitions
                }
            } else if let message = hook["statusMessage"], !(message is NSNull) {
                throw CodexHookAuthorizationError.invalidDefinitions
            }
            entries.append(.init(
                eventName: event, command: installer.hookCommand(for: event),
                key: key, currentHash: hash, trustStatus: trust
            ))
        }
        guard Set(entries.map(\.key)).count == entries.count else {
            throw CodexHookAuthorizationError.invalidDefinitions
        }
        return entries
    }

    private func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        var response = try transport(method, JSONSerialization.data(withJSONObject: params))
        defer { response.resetBytes(in: response.indices) }
        guard response.count <= CodexHookTrustProbe.responseLimitBytes,
              let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              envelope["id"] as? Int == 1, envelope["error"] == nil,
              let result = envelope["result"] as? [String: Any] else {
            throw CodexHookAuthorizationError.requestFailed
        }
        return result
    }

    private static func isSafeText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func isVendorHash(_ value: String) -> Bool {
        value.hasPrefix("sha256:") && value.utf8.count == 71
            && value.dropFirst(7).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func invoke(_ method: String, params: Data) throws -> Data {
        guard let executable = verifiedExecutableURL() else {
            throw CodexHookAuthorizationError.unavailable
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                           "TMPDIR": FileManager.default.temporaryDirectory.path]
        var input = Data([0x0A])
        if method != "--version" {
            let messages: [[String: Any]] = [
                ["method": "initialize", "id": 0, "params": [
                    "clientInfo": ["name": "dev_island", "title": "Dev Island", "version": "0.4.0"],
                ]],
                ["method": "initialized", "params": [:]],
                ["method": method, "id": 1, "params": try JSONSerialization.jsonObject(with: params)],
            ]
            input = Data()
            for message in messages {
                input.append(try JSONSerialization.data(withJSONObject: message))
                input.append(0x0A)
            }
        }
        defer { input.resetBytes(in: input.indices) }
        var buffer = Data()
        defer { buffer.resetBytes(in: buffer.indices) }
        let completion = BoundedStdioChildProcess.requestResponse(
            executableURL: executable, arguments: method == "--version" ? [method] : ["app-server", "--stdio"],
            environment: environment, currentDirectoryURL: home, input: input,
            outputLimit: CodexHookTrustProbe.responseLimitBytes, timeout: 3,
            responseFromChunk: { chunk in
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if method == "--version" { return line }
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       object["id"] as? Int == 1 { return line }
                }
                return nil
            }
        )
        guard case .response(let result) = completion else {
            throw CodexHookAuthorizationError.requestFailed
        }
        return result
    }
}
