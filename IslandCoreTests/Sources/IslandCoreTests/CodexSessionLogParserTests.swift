import Foundation
import XCTest
@testable import IslandCore

final class CodexSessionLogParserTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_788_696_000)

    private func line(_ type: String, at offset: TimeInterval = 0, _ payload: [String: Any]) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try! JSONSerialization.data(withJSONObject: [
            "type": type,
            "timestamp": formatter.string(from: baseDate.addingTimeInterval(offset)),
            "payload": payload
        ])
    }

    private func metadata(_ extra: [String: Any] = [:]) -> Data {
        line("session_meta", [
            "id": "session-1", "cwd": "/Volumes/External/Projects/Example",
            "source": "vscode", "originator": "Codex Desktop"
        ].merging(extra) { _, right in right })
    }

    private func event(
        _ type: String, turn: String? = "turn-1", at offset: TimeInterval = 1,
        extra: [String: Any] = [:]
    ) -> Data {
        var payload = extra
        payload["type"] = type
        if let turn { payload["turn_id"] = turn }
        return line("event_msg", at: offset, payload)
    }

    func testMetadataAndContextDoNotInventRunningWork() {
        var parser = CodexSessionLogParser()
        parser.consume(line: metadata())
        parser.consume(line: line("turn_context", ["turn_id": "turn-1", "cwd": "/project"]))
        parser.consume(line: line("response_item", ["type": "message", "role": "developer"]))
        XCTAssertNil(parser.observation)
        XCTAssertFalse(parser.isIgnoredSession)
    }

    func testRunAndResponseCompletionPreserveEventTimeAndIdentity() throws {
        var parser = CodexSessionLogParser()
        parser.consume(line: metadata())
        parser.consume(line: event("task_started", at: 10))
        let running = try XCTUnwrap(parser.observation)
        XCTAssertEqual(running.task.source, "codex")
        XCTAssertEqual(running.task.id, "session-1")
        XCTAssertEqual(running.task.title, "Example")
        XCTAssertEqual(running.task.taskURL, "file:///Volumes/External/Projects/Example/")
        XCTAssertEqual(running.task.status, .running)
        XCTAssertEqual(running.task.createdAt, baseDate)
        XCTAssertEqual(running.task.updatedAt, baseDate.addingTimeInterval(10))

        parser.consume(line: event("task_complete", at: 20))
        let finished = try XCTUnwrap(parser.observation)
        XCTAssertEqual(finished.turnID, "turn-1")
        XCTAssertEqual(finished.task.status, .completed)
        XCTAssertEqual(finished.task.currentPhase, "Response finished")
        XCTAssertEqual(finished.task.updatedAt, baseDate.addingTimeInterval(20))
        XCTAssertNil(finished.task.waitingMessage)
        XCTAssertNil(finished.task.jumpContext)
    }

    func testHeaderPlusTerminalTailNeedsNoTurnContextOrStartRecord() {
        for completion in ["task_complete", "task_completed"] {
            var parser = CodexSessionLogParser()
            parser.consume(line: metadata(["id": NSNull(), "session_id": "alternate-id"]))
            parser.consume(line: event(completion, at: 30))
            XCTAssertEqual(parser.observation?.task.id, "alternate-id")
            XCTAssertEqual(parser.observation?.task.status, .completed)
            XCTAssertEqual(parser.observation?.task.updatedAt, baseDate.addingTimeInterval(30))
        }
    }

    func testOldTurnEventsCannotOverwriteNewTurnEvenWithLaterTimestamps() {
        var parser = CodexSessionLogParser()
        parser.consume(line: metadata())
        parser.consume(line: event("task_started", turn: "old", at: 1))
        parser.consume(line: event("task_started", turn: "new", at: 3))
        let expected = parser.observation
        parser.consume(line: event("task_complete", turn: "old", at: 4))
        parser.consume(line: event("task_started", turn: "old", at: 5))
        parser.consume(line: event("turn_aborted", turn: "old", at: 6))
        parser.consume(line: event("task_complete", turn: nil, at: 7))
        XCTAssertEqual(parser.observation, expected)

        parser.consume(line: event("task_complete", turn: "new", at: 8))
        XCTAssertEqual(parser.observation?.task.status, .completed)
        parser.consume(line: event("task_started", turn: "new", at: 9))
        XCTAssertEqual(parser.observation?.task.status, .completed)
    }

    func testOlderTimestampAndWrongThreadAreIgnored() {
        var parser = CodexSessionLogParser()
        parser.consume(line: metadata())
        parser.consume(line: event("task_started", at: 20))
        let expected = parser.observation
        parser.consume(line: event("task_complete", at: 10))
        parser.consume(line: event("task_complete", at: 30, extra: ["thread_id": "other-session"]))
        XCTAssertEqual(parser.observation, expected)
    }

    func testSkippedRecordGapClearsTurnGuardButPreservesSessionLabel() {
        var parser = CodexSessionLogParser()
        parser.consume(line: metadata())
        parser.consume(line: event("user_message", extra: ["message": "Fix Codex monitoring"]))
        parser.consume(line: event("task_complete", at: 2))
        parser.resetAfterSkippedRecords()
        XCTAssertNil(parser.observation)

        // The next task_started was inside the skipped burst. Its completion
        // still establishes the new turn without inheriting the old guard.
        parser.consume(line: event("task_complete", turn: "later-turn", at: 30))
        XCTAssertEqual(parser.observation?.turnID, "later-turn")
        XCTAssertEqual(parser.observation?.task.id, "session-1")
        XCTAssertEqual(parser.observation?.task.title, "Fix Codex monitoring")
        XCTAssertEqual(parser.observation?.task.status, .completed)
        XCTAssertEqual(parser.observation?.task.createdAt, baseDate)
        XCTAssertEqual(parser.observation?.task.updatedAt, baseDate.addingTimeInterval(30))

        var helper = CodexSessionLogParser()
        helper.consume(line: metadata(["thread_source": "subagent"]))
        helper.resetAfterSkippedRecords()
        helper.consume(line: event("task_started"))
        XCTAssertTrue(helper.isIgnoredSession)
        XCTAssertNil(helper.observation)
    }

    func testFutureRecordDoesNotPoisonSubsequentRealEvents() {
        var parser = CodexSessionLogParser()
        let now = baseDate.addingTimeInterval(30)
        parser.consume(line: metadata(), referenceDate: now)
        parser.consume(line: event("task_started", at: 1), referenceDate: now)
        let expected = parser.observation
        parser.consume(line: event("task_started", turn: "future-turn", at: 1_000_000), referenceDate: now)
        XCTAssertEqual(parser.observation, expected)
        parser.consume(line: event("task_complete", at: 20), referenceDate: now)
        XCTAssertEqual(parser.observation?.turnID, "turn-1")
        XCTAssertEqual(parser.observation?.task.status, .completed)
        XCTAssertEqual(parser.observation?.task.updatedAt, baseDate.addingTimeInterval(20))
    }

    func testInterruptionStaysFailedUntilAnotherTurnStarts() {
        var parser = CodexSessionLogParser()
        parser.consume(line: metadata())
        parser.consume(line: event("task_started", at: 1))
        parser.consume(line: event("turn_aborted", at: 2, extra: ["reason": "raw private reason"]))
        XCTAssertEqual(parser.observation?.task.status, .failed)
        XCTAssertEqual(parser.observation?.task.currentPhase, "Interrupted")
        parser.consume(line: event("task_complete", at: 3))
        XCTAssertEqual(parser.observation?.task.status, .failed)
        XCTAssertEqual(parser.observation?.task.updatedAt, baseDate.addingTimeInterval(2))
        parser.consume(line: event("task_started", turn: "next", at: 4))
        XCTAssertEqual(parser.observation?.task.status, .running)
        XCTAssertNil(parser.observation?.task.currentPhase)
    }

    func testHelperSessionsAreExcludedAcrossSupportedSourceShapes() {
        let variants: [[String: Any]] = [
            ["source": "subagent"],
            ["source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent"]]]],
            ["thread_source": "subagent"],
            ["originator": "codex_memory_consolidation"],
            ["originator": "Codex Chronicle"]
        ]
        for variant in variants {
            var parser = CodexSessionLogParser()
            parser.consume(line: metadata(variant))
            parser.consume(line: event("task_started"))
            parser.consume(line: event("task_complete", at: 2))
            XCTAssertTrue(parser.isIgnoredSession)
            XCTAssertNil(parser.observation)
        }
    }

    func testInstructionMetadataNeverBecomesAHumanTaskTitleOrActivity() {
        let instructions = [
            "# AGENTS.md instructions\n<INSTRUCTIONS>private context</INSTRUCTIONS>",
            "<environment_context>private path</environment_context>",
            "<instructions>private instruction</instructions>",
            "<recommended_plugins>plugin list</recommended_plugins>",
            "You are Codex, an assistant", " \n "
        ]
        for message in instructions {
            var parser = CodexSessionLogParser()
            parser.consume(line: metadata())
            parser.consume(line: event("user_message", extra: ["message": message]))
            XCTAssertNil(parser.observation)
            parser.consume(line: event("task_started", at: 2))
            XCTAssertEqual(parser.observation?.task.title, "Example")
        }
    }

    func testHumanFirstLineIsBoundedAndRemainsStableAcrossFollowups() {
        var parser = CodexSessionLogParser()
        parser.consume(line: metadata())
        parser.consume(line: event("user_message", extra: ["message": "  Fix the menu click\nPrivate second line"]))
        XCTAssertEqual(parser.observation?.task.title, "Fix the menu click")
        XCTAssertEqual(parser.observation?.task.status, .running)
        parser.consume(line: event("task_complete", at: 2))
        parser.consume(line: event("task_started", turn: "next", at: 3))
        parser.consume(line: event("user_message", turn: "next", at: 4, extra: ["message": "Now adjust spacing"]))
        XCTAssertEqual(parser.observation?.task.title, "Fix the menu click")
    }

    func testCurrentUserMessageItemSkipsMetadataParts() {
        var parser = CodexSessionLogParser()
        parser.consume(line: metadata())
        parser.consume(line: event("item_completed", extra: ["item": [
            "type": "UserMessage", "content": [
                ["type": "text", "text": "<environment_context>metadata</environment_context>"],
                ["type": "text", "text": "Improve Codex monitoring"]
            ]
        ]]))
        XCTAssertEqual(parser.observation?.task.title, "Improve Codex monitoring")
        XCTAssertEqual(parser.observation?.task.status, .running)
    }

    func testToolFailureIsActivityNotResponseFailureOrApproval() {
        var parser = CodexSessionLogParser()
        parser.consume(line: metadata())
        parser.consume(line: event("item_completed", at: 2, extra: ["item": [
            "type": "CommandExecution", "status": "failed", "exit_code": 1,
            "command": ["private command"], "stderr": "private error"
        ]]))
        XCTAssertEqual(parser.observation?.task.status, .running)
        XCTAssertEqual(parser.observation?.task.title, "Example")
        XCTAssertNil(parser.observation?.task.waitingMessage)
        parser.consume(line: event("task_failed", at: 3, extra: ["error": "private raw error"]))
        XCTAssertEqual(parser.observation?.task.status, .failed)
        XCTAssertEqual(parser.observation?.task.currentPhase, "Response failed")
    }

    func testItemActivityRefreshesActualTimeButCannotReopenFinishedTurn() {
        var parser = CodexSessionLogParser()
        parser.consume(line: metadata())
        parser.consume(line: event("task_started", at: 1))
        parser.consume(line: event("item_started", at: 20, extra: ["item": ["type": "McpToolCall"]]))
        XCTAssertEqual(parser.observation?.task.updatedAt, baseDate.addingTimeInterval(20))
        parser.consume(line: event("task_complete", at: 30))
        let expected = parser.observation
        parser.consume(line: event("item_completed", at: 40, extra: ["item": ["type": "AgentMessage"]]))
        XCTAssertEqual(parser.observation, expected)
    }

    func testMalformedUnknownAndOversizedRecordsDoNotMutateTask() {
        var parser = CodexSessionLogParser()
        parser.consume(line: metadata())
        parser.consume(line: event("task_started", at: 1))
        let expected = parser.observation
        let invalid: [Data] = [
            Data(), Data("{broken".utf8), Data("[]".utf8),
            Data("{\"type\":\"event_msg\",\"timestamp\":\"invalid\",\"payload\":{\"type\":\"task_complete\"}}".utf8),
            event("permission_request", at: 2), event("unknown_future_event", at: 3),
            event("task_complete", turn: "bad\nturn", at: 4),
            event("user_message", at: 5, extra: ["message": String(repeating: "x", count: CodexSessionLogParser.maximumLineBytes)])
        ]
        for record in invalid { parser.consume(line: record) }
        XCTAssertEqual(parser.observation, expected)
    }

    func testTitleRespectsCharacterAndByteCapsIncludingHostileGraphemes() throws {
        for message in [String(repeating: "😀", count: 1_000), "x" + String(repeating: "\u{0301}", count: 5_000)] {
            var parser = CodexSessionLogParser()
            parser.consume(line: metadata())
            parser.consume(line: event("task_started"))
            parser.consume(line: event("user_message", at: 2, extra: ["message": message]))
            let title = try XCTUnwrap(parser.observation?.task.title)
            XCTAssertLessThanOrEqual(title.count, CodexSessionLogParser.maximumTitleCharacters)
            XCTAssertLessThanOrEqual(title.utf8.count, CodexSessionLogParser.maximumTitleBytes)
            XCTAssertFalse(title.isEmpty)
        }
    }

    func testInvalidSessionIDsAndRelativeOrControlPathsAreRejected() {
        for id in ["", " \n ", "bad\nid", String(repeating: "a", count: 257)] {
            var parser = CodexSessionLogParser()
            parser.consume(line: metadata(["id": id]))
            parser.consume(line: event("task_started"))
            XCTAssertNil(parser.observation)
        }
        for cwd in ["relative/path", "/project\nprivate", String(repeating: "/a", count: 3_000)] {
            var parser = CodexSessionLogParser()
            parser.consume(line: metadata(["cwd": cwd]))
            parser.consume(line: event("task_started"))
            XCTAssertEqual(parser.observation?.task.title, "Codex session")
            XCTAssertEqual(parser.observation?.task.taskURL, "")
        }
        var parser = CodexSessionLogParser()
        parser.consume(line: metadata(["session_id": "conflicting-id"]))
        parser.consume(line: event("task_started"))
        XCTAssertNil(parser.observation)
    }
}
