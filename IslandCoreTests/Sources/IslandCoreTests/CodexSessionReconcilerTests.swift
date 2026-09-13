import Foundation
import XCTest
@testable import IslandCore

final class CodexSessionReconcilerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_690_000)

    private func task(_ id: String = "session", status: TaskStatus = .running, offset: TimeInterval = 0, title: String = "workspace") -> AgentTask {
        AgentTask(id: id, source: "codex", title: title, status: status,
                  createdAt: now.addingTimeInterval(-60), updatedAt: now.addingTimeInterval(offset),
                  taskURL: "file:///workspace/")
    }

    func testUntrustedHookIsNotRequiredForSessionVisibility() {
        let observed = task(title: "Fix login validation")
        let result = CodexSessionReconciler.reconcile(hooks: [], observations: [
            CodexSessionObservation(task: observed, turnID: "turn")
        ])
        XCTAssertEqual(result, [observed])
    }

    func testOlderLogSuppliesTitleWithoutOverwritingFreshHookState() {
        let hook = task(status: .waiting, offset: 10)
        let observation = CodexSessionObservation(task: task(status: .completed, title: "Fix login validation"), turnID: "old-turn")
        let result = CodexSessionReconciler.reconcile(hooks: [hook], observations: [observation])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.status, .waiting)
        XCTAssertEqual(result.first?.updatedAt, hook.updatedAt)
        XCTAssertEqual(result.first?.title, "Fix login validation")
    }

    func testPendingApprovalWinsEvenOverLaterTerminalLog() {
        let pending = task(status: .waiting)
        let result = CodexSessionReconciler.reconcile(hooks: [pending], observations: [
            CodexSessionObservation(task: task(status: .completed, offset: 20), turnID: "turn")
        ], pendingTasks: [pending])
        XCTAssertEqual(result.first?.status, .waiting)
    }

    func testLogCannotCreateWaitingOrResurrectEndedSession() {
        let result = CodexSessionReconciler.reconcile(hooks: [], observations: [
            CodexSessionObservation(task: task("fake-approval", status: .waiting), turnID: "turn"),
            CodexSessionObservation(task: task("ended", status: .completed), turnID: "turn")
        ], endedSessions: ["ended": now.addingTimeInterval(1)])
        XCTAssertTrue(result.isEmpty)
    }

    func testNewTurnAfterSessionEndCanAppearAgain() {
        let newer = task(status: .running, offset: 2)
        XCTAssertEqual(CodexSessionReconciler.reconcile(hooks: [], observations: [
            CodexSessionObservation(task: newer, turnID: "new-turn")
        ], endedSessions: ["session": now]), [newer])
    }

    @MainActor
    func testRestoredSessionsAreQuietAndRepeatedScanDoesNotNotify() async {
        let store = TaskStore.mock(tasks: [task()])
        var transitions: [TaskTransition] = []
        store.onTaskTransition = { transitions.append($0) }
        let restored = CodexSessionObservation(task: task(status: .completed, offset: 1), turnID: "turn")
        await store.applyCodexSessionObservations([restored], isInitialSnapshot: true)
        await store.applyCodexSessionObservations([restored])
        XCTAssertEqual(store.tasks.first?.status, .completed)
        XCTAssertTrue(transitions.isEmpty)
        let running = CodexSessionObservation(task: task(status: .running, offset: 2), turnID: "next")
        await store.applyCodexSessionObservations([running])
        await store.applyCodexSessionObservations([
            CodexSessionObservation(task: task(status: .completed, offset: 3), turnID: "next")
        ])
        XCTAssertEqual(transitions.map(\.newStatus), [.running, .completed])
        _ = await store.shutdown()
    }

    @MainActor
    func testDelayedHistoricalDiscoveryIsQuietButNewResponseNotifies() async {
        let store = TaskStore.mock(tasks: [task()])
        var transitions: [TaskTransition] = []
        store.onTaskTransition = { transitions.append($0) }
        await store.applyCodexSessionObservations([
            CodexSessionObservation(task: task(status: .completed, offset: 1), turnID: "old")
        ], restoringBefore: now.addingTimeInterval(2))
        XCTAssertTrue(transitions.isEmpty)
        await store.applyCodexSessionObservations([
            CodexSessionObservation(task: task(status: .running, offset: 3), turnID: "new")
        ], restoringBefore: now.addingTimeInterval(2))
        XCTAssertEqual(transitions.map(\.newStatus), [.running])
        _ = await store.shutdown()
    }

    @MainActor
    func testDisablingMonitoringPreservesHookTasksAndOtherAgents() async {
        let other = AgentTask(id: "other", source: "claude-code", title: "Other", status: .running,
                              createdAt: now, updatedAt: now, taskURL: "")
        let store = TaskStore.mock(tasks: [other])
        await store.applyLocalSnapshot(source: "codex", [task("hook")])
        await store.applyCodexSessionObservations([
            CodexSessionObservation(task: task("observed"), turnID: "turn")
        ])
        XCTAssertEqual(store.tasks.count, 3)
        store.setCodexSessionMonitoringEnabled(false)
        XCTAssertEqual(Set(store.tasks.map(\.id)), ["hook", "other"])
        XCTAssertEqual(store.codexSessionMonitorStatus, .stopped)
        await store.applyCodexSessionObservations([
            CodexSessionObservation(task: task("late"), turnID: "turn")
        ])
        XCTAssertEqual(Set(store.tasks.map(\.id)), ["hook", "other"])
        _ = await store.shutdown()
    }

    @MainActor
    func testResolvedApprovalDoesNotReappearFromAnotherSessionsSnapshot() async throws {
        let store = TaskStore.mock(tasks: [])
        var stale = task(status: .waiting)
        stale.updatedAt = Date.now.addingTimeInterval(-60)
        await store.applyLocalSnapshot(source: "codex", [stale])
        let request = AgentActionRequest(source: "codex", sessionId: "session", kind: .permission,
                                         title: "Allow command", message: "Synthetic request", timeout: 5)
        let decision = Task { @MainActor in await store.awaitActionDecision(for: request) }
        for _ in 0..<100 where store.pendingActionRequests.isEmpty { await Task.yield() }
        XCTAssertEqual(store.pendingActionRequests.count, 1)
        XCTAssertTrue(store.respond(to: request.id, decision: .allow))
        let result = await decision.value
        XCTAssertEqual(result, .allow)
        await store.applyLocalSnapshot(source: "codex", [stale, task("sibling")])
        XCTAssertEqual(store.tasks.first(where: { $0.id == "session" })?.status, .running)
        var oldCompletion = stale
        oldCompletion.status = .completed
        oldCompletion.updatedAt = stale.updatedAt.addingTimeInterval(-10)
        await store.applyCodexSessionObservations([
            CodexSessionObservation(task: oldCompletion, turnID: "old")
        ])
        XCTAssertEqual(store.tasks.first(where: { $0.id == "session" })?.status, .running)
        _ = await store.shutdown()
    }

    @MainActor
    func testCancelledApprovalReleasesCachedTerminalObservationWithoutAnotherPoll() async {
        let store = TaskStore.mock(tasks: [])
        await store.applyLocalSnapshot(source: "codex", [task()])
        let request = AgentActionRequest(source: "codex", sessionId: "session", kind: .permission,
                                         title: "Allow command", message: "Synthetic request", timeout: 5)
        let decision = Task { @MainActor in await store.awaitActionDecision(for: request) }
        for _ in 0..<100 where store.pendingActionRequests.isEmpty { await Task.yield() }
        var ended = task(status: .failed)
        ended.updatedAt = Date.now.addingTimeInterval(1)
        let observations = [CodexSessionObservation(task: ended, turnID: "interrupted")]
        await store.applyCodexSessionObservations(observations)
        XCTAssertEqual(store.tasks.first?.status, .waiting)
        store.cancelActionRequests(for: request.taskIdentity)
        XCTAssertEqual(store.tasks.first?.status, .failed,
                       "cancellation must release the cached terminal state without another filesystem event")
        let result = await decision.value
        XCTAssertNil(result)
        XCTAssertEqual(store.tasks.first?.status, .failed)
        _ = await store.shutdown()
    }

    @MainActor
    func testTimedOutApprovalReleasesCachedTerminalObservationWithoutAnotherPoll() async {
        let store = TaskStore.mock(tasks: [])
        await store.applyLocalSnapshot(source: "codex", [task()])
        let request = AgentActionRequest(source: "codex", sessionId: "session", kind: .permission,
                                         title: "Allow command", message: "Synthetic request", timeout: 2)
        let decision = Task { @MainActor in await store.awaitActionDecision(for: request) }
        for _ in 0..<100 where store.pendingActionRequests.isEmpty { await Task.yield() }
        XCTAssertEqual(store.pendingActionRequests.count, 1)
        var ended = task(status: .completed)
        ended.updatedAt = Date.now.addingTimeInterval(1)
        await store.applyCodexSessionObservations([
            CodexSessionObservation(task: ended, turnID: "finished")
        ])
        XCTAssertEqual(store.tasks.first?.status, .waiting)

        // The terminal bytes have already been consumed. No further observation
        // is delivered, so only the actual request timeout can release this row.
        let result = await decision.value
        XCTAssertNil(result)
        XCTAssertTrue(store.pendingActionRequests.isEmpty)
        XCTAssertEqual(store.tasks.first?.status, .completed)
        _ = await store.shutdown()
    }

    @MainActor
    func testPassiveVisibilityDoesNotClaimHooksAreReporting() async {
        let store = TaskStore.mock(tasks: [])
        await store.applyCodexSessionObservations([
            CodexSessionObservation(task: task(), turnID: "turn")
        ])
        XCTAssertFalse(store.liveHookReportingSources.contains("codex"))
        await store.applyLocalSnapshot(source: "codex", [task("hook")])
        XCTAssertTrue(store.liveHookReportingSources.contains("codex"))
        _ = await store.shutdown()
    }

    @MainActor
    func testShutdownRejectsLatePassiveSnapshots() async {
        let store = TaskStore.mock(tasks: [])
        _ = await store.shutdown()
        await store.applyCodexSessionObservations([
            CodexSessionObservation(task: task(), turnID: "turn")
        ])
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertFalse(store.ownsRuntimeResourcesForTesting)
    }
}
