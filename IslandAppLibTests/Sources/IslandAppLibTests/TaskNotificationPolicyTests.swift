import XCTest
@testable import IslandAppLib
import IslandCore

final class TaskNotificationPolicyTests: XCTestCase {
    func testCodexNotificationsDescribeAResponseRatherThanAnEntireTask() {
        XCTAssertEqual(TaskNotificationKind.completed.title(source: "codex", language: .english), "Response finished")
        XCTAssertEqual(TaskNotificationKind.failed.title(source: "codex", language: .simplifiedChinese), "本轮回复已中断")
        XCTAssertEqual(TaskNotificationKind.completed.title(source: "claude-code", language: .english), "Task Completed")
        XCTAssertEqual(TaskNotificationKind.waiting.title(source: "codex", language: .english), "Task Needs Input")
    }

    func testCodexInterruptionIsQuietButAGenuineFailureStillAlerts() {
        func transition(phase: String) -> TaskTransition {
            TaskTransition(
                task: AgentTask(id: "s", source: "codex", title: "t", status: .failed, currentPhase: phase,
                                createdAt: .now, updatedAt: .now, taskURL: "file:///p/"),
                oldStatus: .running
            )
        }
        XCTAssertNil(TaskNotificationKind.decide(
            for: transition(phase: CodexSessionPhase.interrupted), attentionRequired: true, completions: true
        ), "the user stopped the response themselves")
        XCTAssertEqual(TaskNotificationKind.decide(
            for: transition(phase: CodexSessionPhase.responseFailed), attentionRequired: true, completions: true
        ), .failed)
        XCTAssertEqual(TaskNotificationKind.decide(
            for: transition(phase: "Turn failed"), attentionRequired: true, completions: true
        ), .failed, "other Agents' phases are untouched")
    }

    func testNewlyDiscoveredWaitingTaskDoesNotNotify() {
        let transition = TaskTransition(task: task(.waiting), oldStatus: nil)

        XCTAssertNil(TaskNotificationKind.decide(
            for: transition,
            attentionRequired: true,
            completions: true
        ))
    }

    func testWaitingAndFailureAreAttentionNotifications() {
        let waiting = TaskTransition(task: task(.waiting), oldStatus: .running)
        let failed = TaskTransition(task: task(.failed), oldStatus: .running)

        XCTAssertEqual(TaskNotificationKind.decide(
            for: waiting,
            attentionRequired: true,
            completions: false
        ), .waiting)
        XCTAssertEqual(TaskNotificationKind.decide(
            for: failed,
            attentionRequired: true,
            completions: false
        ), .failed)
    }

    func testAttentionToggleSuppressesWaitingAndFailure() {
        for status: TaskStatus in [.waiting, .failed] {
            let transition = TaskTransition(task: task(status), oldStatus: .running)
            XCTAssertNil(TaskNotificationKind.decide(
                for: transition,
                attentionRequired: false,
                completions: true
            ))
        }
    }

    func testCompletionIsOptIn() {
        let transition = TaskTransition(task: task(.completed), oldStatus: .running)

        XCTAssertNil(TaskNotificationKind.decide(
            for: transition,
            attentionRequired: true,
            completions: false
        ))
        XCTAssertEqual(TaskNotificationKind.decide(
            for: transition,
            attentionRequired: true,
            completions: true
        ), .completed)
    }

    func testOnlyAttentionNotificationsInterruptTheIsland() {
        XCTAssertTrue(TaskNotificationKind.waiting.shouldExpandIsland)
        XCTAssertTrue(TaskNotificationKind.failed.shouldExpandIsland)
        XCTAssertFalse(TaskNotificationKind.completed.shouldExpandIsland)
    }

    func testNotificationTitlesFollowTheAppLanguage() {
        XCTAssertEqual(TaskNotificationKind.waiting.title(language: .english), "Task Needs Input")
        XCTAssertEqual(TaskNotificationKind.failed.title(language: .simplifiedChinese), "任务失败")
        XCTAssertEqual(TaskNotificationKind.completed.title(language: .simplifiedChinese), "任务完成")
    }

    func testSemanticStatesUseDistinctBundledSignalSounds() {
        let names = Set([
            TaskNotificationKind.waiting.signalSoundFileName,
            TaskNotificationKind.failed.signalSoundFileName,
            TaskNotificationKind.completed.signalSoundFileName,
        ])

        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("DevIsland-") && $0.hasSuffix(".wav") })
    }

    func testSignalSoundDefaultsOnWithoutChangingCompletionDefault() {
        let suiteName = "TaskNotificationPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TaskNotificationPreferences.registerDefaults(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: TaskNotificationPreferences.attentionRequiredKey))
        XCTAssertFalse(defaults.bool(forKey: TaskNotificationPreferences.completionsKey))
        XCTAssertTrue(defaults.bool(forKey: TaskNotificationPreferences.signalSoundsKey))
    }

    func testSignalGateCoalescesPeersButLetsUrgentFailureCutThrough() {
        var gate = TaskSignalSoundGate()
        let start = Date(timeIntervalSince1970: 10_000)

        XCTAssertTrue(gate.shouldEmit(.completed, at: start, enabled: true))
        XCTAssertFalse(gate.shouldEmit(.completed, at: start.addingTimeInterval(0.2), enabled: true))
        XCTAssertTrue(gate.shouldEmit(.waiting, at: start.addingTimeInterval(0.3), enabled: true))
        XCTAssertFalse(gate.shouldEmit(.waiting, at: start.addingTimeInterval(0.4), enabled: true))
        XCTAssertTrue(gate.shouldEmit(.failed, at: start.addingTimeInterval(0.5), enabled: true))
    }

    func testSignalGateResumesAfterQuietWindowAndNeverEmitsWhenMuted() {
        var gate = TaskSignalSoundGate()
        let start = Date(timeIntervalSince1970: 20_000)

        XCTAssertFalse(gate.shouldEmit(.waiting, at: start, enabled: false))
        XCTAssertTrue(gate.shouldEmit(.waiting, at: start, enabled: true))
        XCTAssertTrue(gate.shouldEmit(
            .waiting,
            at: start.addingTimeInterval(TaskSignalSoundGate.quietWindow),
            enabled: true
        ))
    }

    @MainActor
    func testNotificationSelectionHighlightsTaskAndExpandsPanel() {
        let identity = TaskIdentity(source: "codex", id: "session-1")
        let coordinator = IslandCoordinator.shared
        coordinator.collapse()

        coordinator.expand(highlighting: identity)

        XCTAssertEqual(coordinator.mode, .expanded)
        XCTAssertEqual(coordinator.highlightedTask, identity)

        coordinator.collapse()
        XCTAssertNil(coordinator.highlightedTask)
    }

    @MainActor
    func testProgrammaticOpenStaysUnarmedUntilPointerEngages() {
        let coordinator = IslandCoordinator.shared
        coordinator.collapse()

        coordinator.expand()
        XCTAssertFalse(coordinator.automaticCollapseArmed)

        coordinator.armAutomaticCollapse()
        XCTAssertTrue(coordinator.automaticCollapseArmed)

        coordinator.collapse()
        XCTAssertFalse(coordinator.automaticCollapseArmed)
    }

    @MainActor
    func testDirectIslandClickArmsAutomaticCollapse() {
        let coordinator = IslandCoordinator.shared
        coordinator.collapse()

        coordinator.expandFromPointer()

        XCTAssertEqual(coordinator.mode, .expanded)
        XCTAssertTrue(coordinator.automaticCollapseArmed)

        coordinator.collapse()
    }

    private func task(_ status: TaskStatus) -> AgentTask {
        AgentTask(
            id: "session-1",
            source: "codex",
            title: "DevLand",
            status: status,
            createdAt: .now,
            updatedAt: .now,
            taskURL: "file:///tmp/DevLand"
        )
    }
}
