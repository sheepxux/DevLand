import XCTest
import IslandCore
@testable import IslandAppLib

final class LocalAgentConnectionRowsPresentationTests: XCTestCase {
    func testEveryDiagnosticStateLandsInExactlyOneGroupWithOneAction() {
        XCTAssertEqual(LocalAgentRowPresentation.group(for: .connected), .connected)
        XCTAssertEqual(LocalAgentRowPresentation.group(for: .configured), .needsAttention)
        XCTAssertEqual(LocalAgentRowPresentation.group(for: .updateRequired), .needsAttention)
        XCTAssertEqual(LocalAgentRowPresentation.group(for: .disconnected), .notConnected)
        XCTAssertNil(LocalAgentRowPresentation.group(for: nil), "unknown rows do not jump between groups")

        XCTAssertEqual(LocalAgentRowPresentation.action(for: .connected), .expand)
        XCTAssertEqual(LocalAgentRowPresentation.action(for: .configured), .authorize)
        XCTAssertEqual(LocalAgentRowPresentation.action(for: .updateRequired), .update)
        XCTAssertEqual(LocalAgentRowPresentation.action(for: .disconnected), .connect)
    }

    func testGroupsKeepRegistryOrderInsideAndReadingOrderBetween() {
        let all = LocalAgentRegistry.all
        let states: [String: LocalAgentHookConnectionState] = Dictionary(
            uniqueKeysWithValues: all.enumerated().map { index, descriptor in
                let state: LocalAgentHookConnectionState
                switch index % 4 {
                case 0: state = .disconnected
                case 1: state = .connected
                case 2: state = .updateRequired
                default: state = .configured
                }
                return (descriptor.source, state)
            }
        )
        let grouped = LocalAgentRowPresentation.grouped(all, states: states)

        XCTAssertEqual(grouped.map(\.group), [.connected, .needsAttention, .notConnected])
        for entry in grouped {
            let sources = entry.descriptors.map(\.source)
            let registryOrder = all.map(\.source).filter(sources.contains)
            XCTAssertEqual(sources, registryOrder, "\(String(describing: entry.group))")
        }
        XCTAssertEqual(grouped.flatMap(\.descriptors).count, all.count, "no row is lost or duplicated")
    }

    func testIncompleteSnapshotKeepsEveryRowInOneUngroupedList() {
        let all = LocalAgentRegistry.all
        let partial = [all[0].source: LocalAgentHookConnectionState.connected]
        let grouped = LocalAgentRowPresentation.grouped(all, states: partial)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertNil(grouped[0].group)
        XCTAssertEqual(grouped[0].descriptors.map(\.source), all.map(\.source))
    }

    func testStatusLinesNeverMentionVendorMechanicsAndAreLocalized() {
        let codex = LocalAgentDescriptor.codex
        let claude = LocalAgentDescriptor.claudeCode
        for language in [DevIslandLanguage.english, .simplifiedChinese] {
            for state in [LocalAgentHookConnectionState.connected, .configured, .updateRequired, .disconnected] {
                let line = LocalAgentRowPresentation.statusLine(state: state, descriptor: codex, language: language)
                XCTAssertFalse(line.isEmpty)
                XCTAssertFalse(line.lowercased().contains("hash"), line)
                XCTAssertFalse(line.contains("trusted_hash"), line)
            }
        }
        let english = LocalAgentRowPresentation.statusLine(state: .connected, descriptor: claude, language: .english)
        let chinese = LocalAgentRowPresentation.statusLine(state: .connected, descriptor: claude, language: .simplifiedChinese)
        XCTAssertNotEqual(english, chinese)
        XCTAssertTrue(english.hasPrefix("Connected"))
        XCTAssertEqual(
            LocalAgentRowPresentation.statusLine(state: nil, descriptor: claude, language: .english),
            "Checking…"
        )
    }

    func testSummaryListsOnlyNonZeroCountsInReadingOrder() {
        XCTAssertEqual(
            LocalAgentRowPresentation.summary(connected: 4, needsAttention: 1, notConnected: 3, language: .english),
            "4 connected · 1 need action · 3 not connected"
        )
        XCTAssertEqual(
            LocalAgentRowPresentation.summary(connected: 0, needsAttention: 0, notConnected: 2, language: .english),
            "2 not connected"
        )
        XCTAssertEqual(
            LocalAgentRowPresentation.summary(connected: 4, needsAttention: 1, notConnected: 3, language: .simplifiedChinese),
            "4 个已连接 · 1 个需要处理 · 3 个未连接"
        )
        XCTAssertEqual(
            LocalAgentRowPresentation.summary(connected: 0, needsAttention: 0, notConnected: 0, language: .english),
            "Checking local Agents…"
        )
    }

    func testSnapshotSummaryFoldsConfiguredAndUpdateRequiredIntoAttention() {
        let snapshot = LocalAgentHookHealthSnapshot(agents: [
            .init(source: "a", displayName: "A", state: .connected),
            .init(source: "b", displayName: "B", state: .configured),
            .init(source: "c", displayName: "C", state: .updateRequired),
            .init(source: "d", displayName: "D", state: .disconnected),
        ])
        XCTAssertEqual(
            LocalAgentRowPresentation.summary(snapshot, language: .english),
            "1 connected · 2 need action · 1 not connected"
        )
    }
}
