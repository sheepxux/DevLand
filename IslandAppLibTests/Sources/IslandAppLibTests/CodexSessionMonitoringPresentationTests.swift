import XCTest
import IslandCore
@testable import IslandAppLib

final class CodexSessionMonitoringPresentationTests: XCTestCase {
    private func task(_ status: TaskStatus, phase: String?, source: String = "codex") -> AgentTask {
        AgentTask(id: "s", source: source, title: "Fix login", status: status, currentPhase: phase,
                  createdAt: .now, updatedAt: .now, taskURL: "file:///p/")
    }

    func testFailureAndInterruptionAreDistinguishedByTheMarker() {
        XCTAssertEqual(
            CodexSessionMonitoringPresentation.responseStatus(.failed, phase: CodexSessionPhase.interrupted, language: .english),
            "Response interrupted"
        )
        XCTAssertEqual(
            CodexSessionMonitoringPresentation.responseStatus(.failed, phase: CodexSessionPhase.responseFailed, language: .english),
            "Response failed"
        )
        XCTAssertEqual(
            CodexSessionMonitoringPresentation.responseStatus(.failed, phase: CodexSessionPhase.responseFailed, language: .simplifiedChinese),
            "本轮回复失败"
        )
        XCTAssertEqual(
            CodexSessionMonitoringPresentation.responseStatus(.completed, phase: CodexSessionPhase.responseFinished, language: .simplifiedChinese),
            "本轮回复已结束"
        )
        XCTAssertNil(CodexSessionMonitoringPresentation.responseStatus(.running, phase: nil, language: .english))
    }

    func testDisplayPhaseNeverLeaksAMarkerAndLeavesOtherAgentsAlone() {
        for marker in [CodexSessionPhase.interrupted, CodexSessionPhase.responseFailed, CodexSessionPhase.responseFinished] {
            let status: TaskStatus = marker == CodexSessionPhase.responseFinished ? .completed : .failed
            for language in [DevIslandLanguage.english, .simplifiedChinese] {
                let shown = CodexSessionMonitoringPresentation.displayPhase(for: task(status, phase: marker), language: language)
                XCTAssertNotNil(shown)
                XCTAssertFalse(shown?.contains("codex.") == true, "\(marker) leaked into \(language)")
            }
        }
        XCTAssertNil(CodexSessionMonitoringPresentation.displayPhase(for: task(.running, phase: nil), language: .english))
        XCTAssertEqual(
            CodexSessionMonitoringPresentation.displayPhase(for: task(.failed, phase: "Turn failed", source: "claude-code"), language: .english),
            "Turn failed"
        )
    }
}
