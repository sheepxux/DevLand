import Foundation
import XCTest
@testable import IslandCore

final class LocalAgentActivityProbeTests: XCTestCase {
    private var home: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-island-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func touch(_ relativePath: String, modifiedAt: Date) throws -> URL {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("private session content that must never be read".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }

    func testUnsupportedSourcesAndMissingRootsAreDistinguished() {
        let probe = LocalAgentActivityProbe(homeDirectory: home)
        XCTAssertEqual(probe.activity(for: "cursor"), .unsupported)
        XCTAssertEqual(probe.activity(for: "codex"), .none, "no ~/.codex yet")
        XCTAssertEqual(probe.activity(for: "claude-code"), .none)
    }

    func testCodexNewestRolloutWinsAcrossDateDirectoriesAndArchive() throws {
        _ = try touch(".codex/sessions/2026/09/01/rollout-a.jsonl", modifiedAt: now.addingTimeInterval(-3_600))
        _ = try touch(".codex/sessions/2026/09/05/rollout-b.jsonl", modifiedAt: now.addingTimeInterval(-30))
        _ = try touch(".codex/archived_sessions/rollout-c.jsonl", modifiedAt: now.addingTimeInterval(-600))
        _ = try touch(".codex/sessions/2026/09/05/notes.txt", modifiedAt: now)
        _ = try touch(".codex/sessions/2026/09/05/other-b.jsonl", modifiedAt: now)

        let probe = LocalAgentActivityProbe(homeDirectory: home)
        XCTAssertEqual(probe.activity(for: "codex"), .active(now.addingTimeInterval(-30)))
    }

    func testClaudeProjectsMatchAnyJSONLTranscript() throws {
        _ = try touch(".claude/projects/-Users-x-Project/abc.jsonl", modifiedAt: now.addingTimeInterval(-10))
        _ = try touch(".claude/projects/-Users-x-Project/settings.json", modifiedAt: now)
        let probe = LocalAgentActivityProbe(homeDirectory: home)
        XCTAssertEqual(probe.activity(for: "claude-code"), .active(now.addingTimeInterval(-10)))
    }

    func testSymbolicLinksInsideTheTreeAreNeverFollowed() throws {
        let outside = home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        _ = try touch("outside/rollout-secret.jsonl", modifiedAt: now)
        let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: sessions.appendingPathComponent("linked"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: sessions.appendingPathComponent("rollout-link.jsonl"),
            withDestinationURL: outside.appendingPathComponent("rollout-secret.jsonl")
        )
        let probe = LocalAgentActivityProbe(homeDirectory: home)
        XCTAssertEqual(probe.activity(for: "codex"), .none)
    }

    func testSymbolicLinkRootIsResolvedOnce() throws {
        let realRoot = home.appendingPathComponent("real-codex", isDirectory: true)
        _ = try touch("real-codex/sessions/rollout-a.jsonl", modifiedAt: now.addingTimeInterval(-5))
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".codex"),
            withDestinationURL: realRoot
        )
        let probe = LocalAgentActivityProbe(homeDirectory: home)
        XCTAssertEqual(probe.activity(for: "codex"), .active(now.addingTimeInterval(-5)))
    }

    func testEnumerationIsBounded() throws {
        for index in 0..<40 {
            _ = try touch(".codex/sessions/d/rollout-\(index).jsonl", modifiedAt: now.addingTimeInterval(-Double(index)))
        }
        XCTAssertEqual(LocalAgentActivityProbe.maximumEnumeratedEntries, 8_192)
        let probe = LocalAgentActivityProbe(homeDirectory: home)
        XCTAssertEqual(probe.activity(for: "codex"), .active(now))
    }

    // MARK: - Reporting rule

    private func hooks(_ states: [(String, LocalAgentHookConnectionState)]) -> LocalAgentHookHealthSnapshot {
        LocalAgentHookHealthSnapshot(agents: states.map {
            LocalAgentHookConnection(source: $0.0, displayName: $0.0.capitalized, state: $0.1)
        })
    }

    func testReportingRuleFlagsOnlySilentConnectedAgents() {
        let snapshot = LocalAgentReportingSnapshot.derive(
            hooks: hooks([
                ("codex", .configured),
                ("claude-code", .connected),
                ("cursor", .connected),
                ("gemini-cli", .disconnected),
                ("kimi-code", .updateRequired),
            ]),
            activity: [
                "codex": .active(now.addingTimeInterval(-20)),
                "claude-code": .active(now.addingTimeInterval(-20)),
                "cursor": .unsupported,
                "gemini-cli": .active(now),
            ],
            lastHookEventAt: ["claude-code": now.addingTimeInterval(-15)],
            liveSources: [],
            now: now
        )
        XCTAssertEqual(snapshot.agents.map(\.source), ["codex", "claude-code", "cursor"])
        XCTAssertEqual(snapshot.agents.map(\.state), [.notReporting, .reporting, .unknown])
        XCTAssertEqual(snapshot.notReporting.map(\.source), ["codex"])
    }

    func testLiveSessionOrStaleActivityNeverCountsAsSilence() {
        let stale = LocalAgentReportingSnapshot.derive(
            hooks: hooks([("codex", .connected)]),
            activity: ["codex": .active(now.addingTimeInterval(-3_600))],
            lastHookEventAt: [:],
            liveSources: [],
            now: now
        )
        XCTAssertEqual(stale.agents.map(\.state), [.idle])

        let longTurn = LocalAgentReportingSnapshot.derive(
            hooks: hooks([("codex", .connected)]),
            activity: ["codex": .active(now.addingTimeInterval(-5))],
            lastHookEventAt: ["codex": now.addingTimeInterval(-900)],
            liveSources: ["codex"],
            now: now
        )
        XCTAssertEqual(longTurn.agents.map(\.state), [.reporting], "a live island session proves the Hook ran")

        let quiet = LocalAgentReportingSnapshot.derive(
            hooks: hooks([("codex", .connected)]),
            activity: ["codex": .none],
            lastHookEventAt: [:],
            liveSources: [],
            now: now
        )
        XCTAssertEqual(quiet.agents.map(\.state), [.idle])
    }
}
