import IslandCore
import XCTest
@testable import IslandAppLib

final class LocalAgentReportingPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ agents: [(String, String, LocalAgentReportingState)]) -> LocalAgentReportingSnapshot {
        LocalAgentReportingSnapshot(
            agents: agents.map {
                LocalAgentReportingHealth(source: $0.0, displayName: $0.1, hookState: .configured, state: $0.2)
            },
            observedAt: now
        )
    }

    func testNoNoticeWhenEveryAgentReportsOrNothingIsKnown() {
        XCTAssertNil(LocalAgentReportingPresentation.notice(nil, language: .english))
        XCTAssertNil(LocalAgentReportingPresentation.notice(
            snapshot([("codex", "Codex", .reporting), ("claude-code", "Claude Code", .idle), ("cursor", "Cursor", .unknown)]),
            language: .english
        ))
    }

    func testCodexNoticePointsAtTheReviewCommandInBothLanguages() {
        let notice = LocalAgentReportingPresentation.notice(
            snapshot([("claude-code", "Claude Code", .notReporting), ("codex", "Codex", .notReporting)]),
            language: .english
        )
        XCTAssertEqual(notice?.source, "codex", "Codex first: its trust gate is the common cause")
        XCTAssertEqual(notice?.title, "Codex is running but not reporting to the island.")
        XCTAssertEqual(notice?.hint, "Check session monitoring and approval authorization in Settings › Agents.")

        let chinese = LocalAgentReportingPresentation.notice(
            snapshot([("codex", "Codex", .notReporting)]),
            language: .simplifiedChinese
        )
        XCTAssertEqual(chinese?.title, "Codex 正在运行，但没有向岛汇报。")
        XCTAssertEqual(chinese?.hint, "在设置 › Agent 中检查会话监控和审批授权。")
    }

    func testOtherAgentsPointAtSettings() {
        let notice = LocalAgentReportingPresentation.notice(
            snapshot([("claude-code", "Claude Code", .notReporting)]),
            language: .english
        )
        XCTAssertEqual(notice?.title, "Claude Code is running but not reporting to the island.")
        XCTAssertEqual(notice?.hint, "Update its hook in Settings › Agents.")
        let chinese = LocalAgentReportingPresentation.notice(
            snapshot([("claude-code", "Claude Code", .notReporting)]),
            language: .simplifiedChinese
        )
        XCTAssertEqual(chinese?.hint, "在设置 › Agent 中更新它的 Hook。")
    }

    func testNoticeCarriesNoPathsOrSessionIdentifiers() {
        let notice = LocalAgentReportingPresentation.notice(
            snapshot([("codex", "Codex", .notReporting)]),
            language: .english
        )
        XCTAssertFalse(notice?.accessibilityLabel.contains("/Users") ?? true)
        XCTAssertFalse(notice?.accessibilityLabel.contains("rollout") ?? true)
    }
}
