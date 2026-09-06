import AppKit
import IslandCore
import XCTest
@testable import IslandAppLib

final class CodexTrustGuidanceTests: XCTestCase {
    func testEntryNamesComeFromTheInstallerDefinitionNotACopy() {
        XCTAssertEqual(CodexTrustGuidance.entryNames(), LocalAgentDescriptor.codex.hookEvents)
        XCTAssertEqual(CodexTrustGuidance.entryNames().count, 5)
        XCTAssertEqual(CodexTrustGuidance.reviewCommand(), "/hooks")
        XCTAssertNil(CodexTrustGuidance.reviewCommand(descriptor: .claudeCode), "only Codex has a trust gate")
    }

    func testCopyIsLocalizedAndNamesTheReviewCommand() {
        XCTAssertEqual(
            CodexTrustGuidance.summary(language: .english),
            "Codex trusts a hook once. Open Codex, run /hooks, and trust these 5 Dev Island entries:"
        )
        XCTAssertEqual(
            CodexTrustGuidance.summary(language: .simplifiedChinese),
            "Codex 只需信任一次 Hook。打开 Codex，输入 /hooks，信任下面这 5 条 Dev Island 条目："
        )
        XCTAssertEqual(CodexTrustGuidance.actionTitle(language: .english), "Open Codex and copy /hooks")
        XCTAssertEqual(CodexTrustGuidance.actionTitle(language: .simplifiedChinese), "打开 Codex 并复制 /hooks")
    }

    func testActionFillsThePasteboardEvenWhenCodexIsAbsent() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        _ = CodexTrustGuidance.openCodexAndCopyReviewCommand(pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "/hooks")
    }
}
