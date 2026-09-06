import Foundation
import XCTest
@testable import IslandCore

final class CodexSessionLogMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_696_000) // 2026-09-06 12:00 UTC
    private var temporary: URL!
    private var root: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("CodexSessionMonitor-\(UUID().uuidString)", isDirectory: true)
        root = temporary.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    func testRecentSessionAppearsAndPollingPreservesSourceTimestamp() async throws {
        try rollout("one", content: metadata("one") + event("task_started", at: now))
        let monitor = CodexSessionLogMonitor(root: root)
        let first = await monitor.poll(now: now)
        let second = await monitor.poll(now: now.addingTimeInterval(60))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.task.id, "one")
        XCTAssertEqual(first.first?.task.status, .running)
        XCTAssertEqual(first.first?.task.updatedAt, now)
        XCTAssertEqual(first, second)
        let status = await monitor.status
        XCTAssertEqual(status, .available)
    }

    func testAppendWaitsForCompleteJSONLineThenEndsTheTurn() async throws {
        let complete = event("task_complete", at: now.addingTimeInterval(5))
        let split = complete.index(complete.startIndex, offsetBy: complete.count / 2)
        let file = try rollout("one", content: metadata("one") + event("task_started", at: now) + String(complete[..<split]))
        let monitor = CodexSessionLogMonitor(root: root)
        let initial = await monitor.poll(now: now)
        XCTAssertEqual(initial.first?.task.status, .running)
        try append(String(complete[split...].dropLast()), to: file)
        let partial = await monitor.poll(now: now.addingTimeInterval(5))
        XCTAssertEqual(partial.first?.task.status, .running)
        try append("\n", to: file)
        let ended = await monitor.poll(now: now.addingTimeInterval(5))
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.task.status, .completed)
        XCTAssertEqual(ended.first?.task.updatedAt, now.addingTimeInterval(5))
    }

    func testTruncationAndAtomicReplacementDiscardPreviousSession() async throws {
        let file = try rollout("one", content: metadata("old") + event("task_started", at: now) + String(repeating: " ", count: 1_024) + "\n")
        let monitor = CodexSessionLogMonitor(root: root)
        _ = await monitor.poll(now: now)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((metadata("truncated") + event("task_started", at: now)).utf8))
        try handle.close()
        let truncated = await monitor.poll(now: now)
        XCTAssertEqual(truncated.map(\.task.id), ["truncated"])

        try Data((metadata("replacement") + event("task_complete", at: now)).utf8).write(to: file, options: .atomic)
        let replaced = await monitor.poll(now: now)
        XCTAssertEqual(replaced.map(\.task.id), ["replacement"])
        XCTAssertEqual(replaced.first?.task.status, .completed)
    }

    func testRewriteGrowingSameFileDetectsChangedHeader() async throws {
        let file = try rollout("one", content: metadata("old") + event("task_started", at: now))
        let monitor = CodexSessionLogMonitor(root: root)
        _ = await monitor.poll(now: now)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((metadata("new-longer-session") + event("task_complete", at: now) + "{}\n").utf8))
        try handle.close()
        let replaced = await monitor.poll(now: now)
        XCTAssertEqual(replaced.map(\.task.id), ["new-longer-session"])
    }

    func testDeletedOrArchivedFileDoesNotLeaveGhostTask() async throws {
        let file = try rollout("one", content: metadata("one") + event("task_started", at: now))
        let monitor = CodexSessionLogMonitor(root: root)
        _ = await monitor.poll(now: now)
        let archive = temporary.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: archive.appendingPathComponent(file.lastPathComponent))
        let archived = await monitor.poll(now: now)
        XCTAssertTrue(archived.isEmpty)
    }

    func testStaleBootstrapAndStaleActiveTasksAreHiddenDespiteRecentMtime() async throws {
        try rollout("old-active", content: metadata("old-active") + event("task_started", at: now.addingTimeInterval(-31 * 60)))
        try rollout("old-ended", content: metadata("old-ended") + event("task_complete", at: now.addingTimeInterval(-121 * 60)))
        try rollout("recent-ended", content: metadata("recent-ended") + event("task_complete", at: now.addingTimeInterval(-60)))
        try rollout("metadata-only", content: metadata("metadata-only"))
        try rollout("subagent", content: metadata("subagent", source: "subagent") + event("task_started", at: now))
        let monitor = CodexSessionLogMonitor(root: root)
        let observations = await monitor.poll(now: now)
        XCTAssertEqual(observations.map(\.task.id), ["recent-ended"])
        let expired = await monitor.poll(now: now.addingTimeInterval(2 * 60 * 60))
        XCTAssertTrue(expired.isEmpty)
    }

    func testOldCreationDateWithRecentActivityIsDiscovered() async throws {
        try rollout("yesterday", date: now.addingTimeInterval(-86_400), content: metadata("yesterday") + event("task_started", at: now))
        try rollout("old-folder", date: now.addingTimeInterval(-4 * 86_400), content: metadata("old-folder") + event("task_started", at: now))
        let monitor = CodexSessionLogMonitor(root: root)
        let observations = await monitor.poll(now: now)
        XCTAssertEqual(Set(observations.map(\.task.id)), Set(["yesterday", "old-folder"]))
    }

    func testTrackedOlderSessionIsRefreshedBetweenDiscoverySweeps() async throws {
        let file = try rollout("old-folder", date: now.addingTimeInterval(-90 * 86_400), content: metadata("old-folder") + event("task_started", at: now))
        let monitor = CodexSessionLogMonitor(root: root)
        let started = await monitor.poll(now: now)
        XCTAssertEqual(started.first?.task.status, .running)
        try append(event("task_complete", at: now.addingTimeInterval(1)), to: file)
        let ended = await monitor.poll(now: now.addingTimeInterval(1))
        XCTAssertEqual(ended.first?.task.status, .completed)
    }

    func testOlderFolderAddedLaterIsFoundByBoundedRediscovery() async throws {
        let monitor = CodexSessionLogMonitor(root: root)
        _ = await monitor.poll(now: now)
        try rollout("old-folder", date: now.addingTimeInterval(-90 * 86_400), content: metadata("old-folder") + event("task_started", at: now))
        let beforeSweep = await monitor.poll(now: now.addingTimeInterval(1))
        XCTAssertTrue(beforeSweep.isEmpty)
        let afterSweep = await monitor.poll(now: now.addingTimeInterval(11))
        XCTAssertEqual(afterSweep.map(\.task.id), ["old-folder"])
    }

    func testEnumerationLimitReportsDegradedInsteadOfAvailable() async throws {
        var limits = CodexSessionLogMonitor.Limits()
        limits.maximumEntries = 3
        try rollout("one", content: metadata("one") + event("task_started", at: now))
        let monitor = CodexSessionLogMonitor(root: root, limits: limits)
        _ = await monitor.poll(now: now)
        let limited = await monitor.status
        XCTAssertEqual(limited, .unavailable)
        _ = await monitor.poll(now: now.addingTimeInterval(1))
        let cachedLimited = await monitor.status
        XCTAssertEqual(cachedLimited, .unavailable)
    }

    func testSymbolicFilesAndDateDirectoriesCannotEscapeRoot() async throws {
        let safe = try rollout("safe", content: metadata("safe") + event("task_started", at: now))
        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("rollout-escape.jsonl")
        try Data((metadata("escape") + event("task_started", at: now)).utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(at: safe.deletingLastPathComponent().appendingPathComponent("rollout-symlink.jsonl"), withDestinationURL: outsideFile)
        let yesterday = dateDirectory(now.addingTimeInterval(-86_400))
        try FileManager.default.createSymbolicLink(at: yesterday, withDestinationURL: outside)
        let monitor = CodexSessionLogMonitor(root: root)
        let observations = await monitor.poll(now: now)
        XCTAssertEqual(observations.map(\.task.id), ["safe"])

        let rootLink = temporary.appendingPathComponent("linked-sessions")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: root)
        let linked = CodexSessionLogMonitor(root: rootLink)
        let linkedObservations = await linked.poll(now: now)
        let linkedStatus = await linked.status
        XCTAssertTrue(linkedObservations.isEmpty)
        XCTAssertEqual(linkedStatus, .unavailable)
    }

    func testOversizedAndMalformedLinesDoNotBlockLaterLifecycleEvent() async throws {
        var limits = CodexSessionLogMonitor.Limits()
        limits.lineBytes = 512
        let file = try rollout("one", content: metadata("one") + "not json\n" + event("task_started", at: now) + String(repeating: "x", count: 2_000))
        let monitor = CodexSessionLogMonitor(root: root, limits: limits)
        let running = await monitor.poll(now: now)
        XCTAssertEqual(running.first?.task.status, .running)
        try append("\n" + event("task_complete", at: now.addingTimeInterval(1)), to: file)
        let ended = await monitor.poll(now: now.addingTimeInterval(1))
        XCTAssertEqual(ended.first?.task.status, .completed)
    }

    func testLargeBootstrapReadsHeaderAndTailWithoutReplayingOldMiddle() async throws {
        var limits = CodexSessionLogMonitor.Limits()
        limits.headerBytes = 512
        limits.tailBytes = 1_024
        limits.pollBytes = 2_048
        let content = metadata("one") + event("task_started", at: now.addingTimeInterval(-86_400)) + String(repeating: "private prompt ignored\n", count: 2_000) + event("task_complete", at: now)
        try rollout("one", content: content)
        let monitor = CodexSessionLogMonitor(root: root, limits: limits)
        let observations = await monitor.poll(now: now)
        XCTAssertEqual(observations.map(\.task.id), ["one"])
        XCTAssertEqual(observations.first?.task.status, .completed)
        XCTAssertEqual(observations.first?.task.updatedAt, now)
    }

    func testLargeValidMetadataHeaderIsNotLostDuringTailBootstrap() async throws {
        let largeHeader = metadata("one").replacingOccurrences(of: "\"cwd\":", with: "\"unused\":\"\(String(repeating: "x", count: 80 * 1_024))\",\"cwd\":")
        try rollout("one", content: largeHeader + String(repeating: "ignored\n", count: 100_000) + event("task_complete", at: now))
        let monitor = CodexSessionLogMonitor(root: root)
        let observations = await monitor.poll(now: now)
        XCTAssertEqual(observations.map(\.task.id), ["one"])
        XCTAssertEqual(observations.first?.task.status, .completed)
    }

    func testLargeAppendGapCanObserveDifferentTurnCompletion() async throws {
        var limits = CodexSessionLogMonitor.Limits()
        limits.tailBytes = 1_024
        let file = try rollout("one", content: metadata("one") + event("task_started", at: now))
        let monitor = CodexSessionLogMonitor(root: root, limits: limits)
        _ = await monitor.poll(now: now)
        let nextTurn = event("task_complete", at: now.addingTimeInterval(1)).replacingOccurrences(of: "turn-1", with: "turn-2")
        try append(String(repeating: "ignored\n", count: 1_000) + nextTurn, to: file)
        let observations = await monitor.poll(now: now.addingTimeInterval(1))
        XCTAssertEqual(observations.first?.task.status, .completed)
        XCTAssertEqual(observations.first?.turnID, "turn-2")
    }

    func testCandidateLimitSelectsNewestAndIgnoresNonRolloutFiles() async throws {
        var limits = CodexSessionLogMonitor.Limits()
        limits.maximumFiles = 2
        for index in 0..<4 {
            let file = try rollout("\(index)", content: metadata("\(index)") + event("task_started", at: now))
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(index))], ofItemAtPath: file.path)
        }
        try Data((metadata("noise") + event("task_started", at: now)).utf8).write(to: dateDirectory(now).appendingPathComponent("unrelated.jsonl"))
        let monitor = CodexSessionLogMonitor(root: root, limits: limits)
        let observations = await monitor.poll(now: now)
        XCTAssertEqual(Set(observations.map(\.task.id)), Set(["2", "3"]))
    }

    func testPollBudgetDefersBootstrapAndNextPollMakesProgress() async throws {
        var limits = CodexSessionLogMonitor.Limits()
        let content = metadata("one") + event("task_started", at: now)
        limits.pollBytes = content.utf8.count + 64
        try rollout("one", content: content)
        try rollout("two", content: content.replacingOccurrences(of: "one", with: "two"))
        let monitor = CodexSessionLogMonitor(root: root, limits: limits)
        let first = await monitor.poll(now: now)
        XCTAssertEqual(first.count, 1)
        let second = await monitor.poll(now: now.addingTimeInterval(1))
        XCTAssertEqual(Set(second.map(\.task.id)), Set(["one", "two"]))
    }

    func testFutureEventCannotHideSubsequentValidActivity() async throws {
        try rollout("one", content: metadata("one") + event("task_started", at: now.addingTimeInterval(86_400)) + event("task_complete", at: now))
        let monitor = CodexSessionLogMonitor(root: root)
        let observations = await monitor.poll(now: now)
        XCTAssertEqual(observations.map(\.task.id), ["one"])
        XCTAssertEqual(observations.first?.task.status, .completed)
        XCTAssertEqual(observations.first?.task.updatedAt, now)
    }

    func testMissingRootIsReportedAndCanRecover() async throws {
        try FileManager.default.removeItem(at: root)
        let monitor = CodexSessionLogMonitor(root: root)
        let missing = await monitor.poll(now: now)
        let missingStatus = await monitor.status
        XCTAssertTrue(missing.isEmpty)
        XCTAssertEqual(missingStatus, .notFound)
        try rollout("one", content: metadata("one") + event("task_started", at: now))
        let recovered = await monitor.poll(now: now)
        let recoveredStatus = await monitor.status
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recoveredStatus, .available)
    }

    @discardableResult
    private func rollout(_ name: String, date: Date? = nil, content: String) throws -> URL {
        let directory = dateDirectory(date ?? now)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-\(name).jsonl")
        try Data(content.utf8).write(to: file)
        return file
    }

    private func dateDirectory(_ date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/dd"
        return root.appendingPathComponent(formatter.string(from: date), isDirectory: true)
    }

    private func metadata(_ id: String, source: String = "vscode") -> String {
        "{\"timestamp\":\"\(timestamp(now))\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/project\",\"source\":\"\(source)\",\"originator\":\"Codex Desktop\"}}\n"
    }

    private func event(_ type: String, at date: Date) -> String {
        "{\"timestamp\":\"\(timestamp(date))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\"turn-1\"}}\n"
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
