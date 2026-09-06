import Foundation

/// A read-only observation, never an approval request. The timestamp belongs
/// to the recorded event, so replaying a file cannot make old work look live.
struct CodexSessionObservation: Equatable, Sendable {
    let task: AgentTask
    let turnID: String?
}

/// Consumes complete JSONL records while retaining only bounded task metadata.
/// The file monitor owns framing, file limits, and stale filtering, and supplies
/// a reference date so future records are rejected before they change state.
struct CodexSessionLogParser {
    static let maximumLineBytes = 256 * 1_024
    static let maximumTitleCharacters = 120
    static let maximumTitleBytes = 512

    private(set) var observation: CodexSessionObservation?
    private(set) var isIgnoredSession = false
    private var sessionID: String?
    private var cwd: String?
    private var sessionCreatedAt: Date?
    private var humanTitle: String?
    private var retiredTurnIDs: [String] = []

    init() {}

    /// The monitor deliberately skipped a span of records to stay within its
    /// read budget. A new turn may have begun in that gap: retain the session
    /// label, but do not apply the previous turn's ordering guard to its tail.
    mutating func resetAfterSkippedRecords() {
        observation = nil
        retiredTurnIDs.removeAll(keepingCapacity: true)
    }

    mutating func consume(line: Data, referenceDate: Date? = nil) {
        guard !isIgnoredSession,
              !line.isEmpty, line.count <= Self.maximumLineBytes,
              let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = record["type"] as? String,
              let payload = record["payload"] as? [String: Any] else { return }

        if type == "session_meta" {
            consumeMetadata(payload, timestamp: Self.date(record["timestamp"]))
            return
        }
        guard type == "event_msg", let sessionID,
              let date = Self.date(record["timestamp"]),
              let event = payload["type"] as? String else { return }
        // Reject before mutation: filtering only the resulting snapshot would
        // leave a far-future updatedAt that rejects every subsequent real event.
        if let referenceDate, date.timeIntervalSince(referenceDate) > 5 * 60 { return }
        if let rawThreadID = payload["thread_id"] as? String,
           LocalAgentEvent.validSessionId(rawThreadID) != sessionID { return }
        if let previous = observation, date < previous.task.updatedAt { return }

        let turnID = LocalAgentEvent.validSessionId(payload["turn_id"] as? String)
        // A present but malformed ID must not become an unscoped event.
        if payload["turn_id"] != nil, turnID == nil { return }
        if let turnID, retiredTurnIDs.contains(turnID) { return }

        switch event {
        case "task_started":
            beginTurn(turnID, at: date)
        case "user_message":
            consumeUserMessage(payload["message"] as? String, turnID: turnID, at: date)
        case "task_complete", "task_completed":
            finishTurn(turnID, at: date, status: .completed, phase: "Response finished")
        case "turn_aborted":
            finishTurn(turnID, at: date, status: .failed, phase: "Interrupted")
        case "task_failed", "turn_failed":
            finishTurn(turnID, at: date, status: .failed, phase: "Response failed")
        case "item_started", "item_completed":
            consumeItem(payload["item"] as? [String: Any], turnID: turnID, at: date)
        default:
            break
        }
    }

    private mutating func consumeMetadata(_ payload: [String: Any], timestamp: Date?) {
        if Self.isHelperSource(payload["source"])
            || Self.isHelperSource(payload["thread_source"])
            || Self.isHelperSource(payload["originator"]) {
            isIgnoredSession = true
            observation = nil
            return
        }
        let id = LocalAgentEvent.validSessionId(payload["id"] as? String)
        let alternateID = LocalAgentEvent.validSessionId(payload["session_id"] as? String)
        guard let validID = id ?? alternateID else { return }
        if let id, let alternateID, id != alternateID { return }
        if let sessionID, sessionID != validID { return }
        sessionID = validID
        // Reuse the hook boundary's absolute-path and control-character checks.
        cwd = LocalAgentEvent(
            sessionId: validID, cwd: payload["cwd"] as? String, action: .ignored
        ).cwd
        sessionCreatedAt = sessionCreatedAt ?? Self.date(payload["timestamp"]) ?? timestamp
    }

    private mutating func beginTurn(_ turnID: String?, at date: Date) {
        if let turnID, let previous = observation, previous.turnID == turnID,
           previous.task.status != .running { return }
        retirePreviousTurn(replacingWith: turnID)
        update(at: date, turnID: turnID, status: .running, phase: nil)
    }

    private mutating func consumeUserMessage(_ text: String?, turnID: String?, at date: Date) {
        guard let title = Self.safeHumanTitle(text) else { return }
        if let current = observation?.turnID, let turnID, current != turnID { return }
        humanTitle = humanTitle ?? title
        if let previous = observation, previous.task.status != .running,
           turnID != nil, previous.turnID == turnID { return }
        retirePreviousTurn(replacingWith: turnID ?? activeTurnID)
        update(at: date, turnID: turnID ?? activeTurnID, status: .running, phase: nil)
    }

    private mutating func consumeItem(_ item: [String: Any]?, turnID: String?, at date: Date) {
        guard let item, let type = item["type"] as? String else { return }
        if type == "UserMessage" || type == "user_message" {
            let content = item["content"] as? [[String: Any]] ?? []
            // Metadata can be a separate text part; never use it as a title.
            let title = content.prefix(32).lazy.compactMap { part -> String? in
                guard let kind = part["type"] as? String,
                      kind == "text" || kind == "input_text" else { return nil }
                return Self.safeHumanTitle(part["text"] as? String)
            }.first
            consumeUserMessage(title, turnID: turnID, at: date)
            return
        }
        let activityTypes: Set<String> = [
            "AgentMessage", "Reasoning", "CommandExecution", "McpToolCall",
            "FileChange", "WebSearch", "ImageView", "CollabAgentToolCall",
            "agent_message", "reasoning", "command_execution", "mcp_tool_call",
            "file_change", "web_search"
        ]
        guard activityTypes.contains(type), matchesCurrentTurn(turnID) else { return }
        // An individual tool can fail and the agent can recover. Neither its
        // failure nor its completion establishes the outcome of the response.
        if let previous = observation, previous.task.status != .running { return }
        update(at: date, turnID: turnID ?? activeTurnID, status: .running, phase: nil)
    }

    private mutating func finishTurn(
        _ turnID: String?, at date: Date, status: TaskStatus, phase: String
    ) {
        guard matchesCurrentTurn(turnID) else { return }
        // Once interrupted/failed, a duplicate generic completion must not
        // turn that response green. A subsequent task_started opens a new turn.
        if observation?.task.status == .failed, status == .completed { return }
        update(at: date, turnID: turnID ?? activeTurnID, status: status, phase: phase)
    }

    private var activeTurnID: String? {
        observation?.task.status == .running ? observation?.turnID : nil
    }

    private func matchesCurrentTurn(_ turnID: String?) -> Bool {
        guard let current = observation?.turnID else { return true }
        // Modern records always carry a turn ID. An unscoped terminal/item
        // event cannot safely finish or refresh a known modern turn.
        return turnID == current
    }

    private mutating func retirePreviousTurn(replacingWith turnID: String?) {
        guard let previous = observation?.turnID, previous != turnID else { return }
        retiredTurnIDs.append(previous)
        if retiredTurnIDs.count > 32 { retiredTurnIDs.removeFirst() }
    }

    private mutating func update(at date: Date, turnID: String?, status: TaskStatus, phase: String?) {
        guard let sessionID else { return }
        let url = cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let fallback = url?.lastPathComponent ?? "Codex session"
        let title = humanTitle ?? AgentActionTextPolicy.boundedNonempty(
            fallback, maximumCharacters: Self.maximumTitleCharacters,
            maximumUTF8Bytes: Self.maximumTitleBytes
        ) ?? "Codex session"
        observation = CodexSessionObservation(
            task: AgentTask(
                id: sessionID, source: "codex", title: title,
                status: status, currentPhase: phase,
                createdAt: observation?.task.createdAt ?? min(sessionCreatedAt ?? date, date),
                updatedAt: date, taskURL: url?.absoluteString ?? ""
            ),
            turnID: turnID
        )
    }

    private static func safeHumanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.prefix(128).lowercased()
        let metadataPrefixes = [
            "# agents.md", "<instructions", "<environment_context", "<permissions",
            "<collaboration_mode", "<app-context", "<app_context", "<user_instructions",
            "<system", "<developer", "<recommended_plugins", "<skills_instructions",
            "<turn_aborted", "you are codex", "you are an ai assistant"
        ]
        guard !metadataPrefixes.contains(where: lower.hasPrefix),
              let firstLine = trimmed.split(whereSeparator: \.isNewline).first else { return nil }
        let safe = String(String.UnicodeScalarView(firstLine.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
        return AgentActionTextPolicy.boundedNonempty(
            safe, maximumCharacters: maximumTitleCharacters, maximumUTF8Bytes: maximumTitleBytes
        )
    }

    private static func isHelperSource(_ value: Any?, depth: Int = 0) -> Bool {
        guard depth < 5 else { return false }
        if let text = value as? String {
            let lower = text.lowercased()
            return lower.contains("subagent") || lower.contains("memory") || lower.contains("chronicle")
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.contains { key, value in
                isHelperSource(key, depth: depth + 1) || isHelperSource(value, depth: depth + 1)
            }
        }
        return false
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, text.utf8.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
