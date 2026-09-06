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

    func testManualInstructionsUseCLINotDesktopChatInBothLanguages() {
        for language in [DevIslandLanguage.english, .simplifiedChinese] {
            let manual = CodexTrustGuidance.manualInstructions(language: language)
            XCTAssertTrue(manual.contains("Codex CLI"))
            XCTAssertTrue(manual.contains("/hooks"))
            XCTAssertFalse(CodexTrustGuidance.actionTitle(language: language).contains("/hooks"))
        }
    }

    func testFallbackCopiesOnlyAShellQuotedExecutableAndDoesNotLaunchDesktop() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let executable = URL(fileURLWithPath: "/Applications/Codex's App.app/Contents/Resources/codex")
        XCTAssertTrue(CodexTrustGuidance.copyCLILaunchCommand(pasteboard: pasteboard, executableURL: executable))
        XCTAssertEqual(pasteboard.string(forType: .string), "'/Applications/Codex'\\''s App.app/Contents/Resources/codex'")
        XCTAssertFalse(pasteboard.string(forType: .string)?.contains("/hooks") ?? true)
    }

    func testMissingVerifiedCLILeavesClipboardUntouched() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("user clipboard", forType: .string)
        XCTAssertFalse(CodexTrustGuidance.copyCLILaunchCommand(pasteboard: pasteboard, executableURL: nil))
        XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")
        XCTAssertNil(CodexTrustGuidance.launcherCommand(executableURL: URL(string: "https://example.com/codex")))
        XCTAssertNil(CodexTrustGuidance.launcherCommand(executableURL: URL(fileURLWithPath: "/tmp/codex\ncommand")))
    }

    func testMonitoringAndApprovalGuidanceRemainDistinctInBothLanguages() {
        XCTAssertTrue(CodexTrustGuidance.summary(language: .english).contains("independently"))
        XCTAssertTrue(CodexTrustGuidance.summary(language: .simplifiedChinese).contains("独立"))
        for status: CodexSessionMonitorStatus in [.stopped, .notFound, .available, .unavailable] {
            let english = CodexSessionMonitoringPresentation.status(status, language: .english)
            let chinese = CodexSessionMonitoringPresentation.status(status, language: .simplifiedChinese)
            XCTAssertNotEqual(english, chinese)
            XCTAssertFalse(english.contains("trust"))
        }
    }
}
