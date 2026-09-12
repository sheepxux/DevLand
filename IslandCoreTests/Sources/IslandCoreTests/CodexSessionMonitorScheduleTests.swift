import Foundation
import XCTest
@testable import IslandCore

final class CodexSessionMonitorScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private func observation(_ status: TaskStatus, ageSeconds: TimeInterval) -> CodexSessionObservation {
        CodexSessionObservation(
            task: AgentTask(
                id: "session-\(ageSeconds)", source: "codex", title: "workspace", status: status,
                createdAt: now.addingTimeInterval(-ageSeconds - 60), updatedAt: now.addingTimeInterval(-ageSeconds),
                taskURL: "file:///workspace/"
            ),
            turnID: "turn"
        )
    }

    func testNoObservationsMeansNoDeadline() {
        XCTAssertNil(CodexSessionMonitorSchedule.nextDeadline(for: [], hasDeferredReads: false, now: now))
    }

    func testRunningRowExpiresThirtyMinutesAfterItsLastEvent() {
        let deadline = CodexSessionMonitorSchedule.nextDeadline(
            for: [observation(.running, ageSeconds: 5 * 60)], hasDeferredReads: false, now: now
        )
        XCTAssertEqual(deadline, now.addingTimeInterval(25 * 60))
    }

    func testEndedRowsExpireTwoHoursAfterTheirLastEvent() {
        for status in [TaskStatus.completed, .failed, .waiting] {
            let deadline = CodexSessionMonitorSchedule.nextDeadline(
                for: [observation(status, ageSeconds: 60 * 60)], hasDeferredReads: false, now: now
            )
            XCTAssertEqual(deadline, now.addingTimeInterval(60 * 60), "\(status)")
        }
    }

    func testEarliestExpiryWinsAndNeverPrecedesTheMinimumDelay() {
        let deadline = CodexSessionMonitorSchedule.nextDeadline(
            for: [
                observation(.completed, ageSeconds: 10),
                observation(.running, ageSeconds: 29 * 60 + 59.9),
                observation(.running, ageSeconds: 31 * 60),
            ],
            hasDeferredReads: false,
            now: now
        )
        XCTAssertEqual(deadline, now.addingTimeInterval(CodexSessionMonitorSchedule.minimumDelay))
    }

    func testDeferredReadsScheduleThePromptRetry() {
        let deadline = CodexSessionMonitorSchedule.nextDeadline(
            for: [observation(.completed, ageSeconds: 10)], hasDeferredReads: true, now: now
        )
        XCTAssertEqual(deadline, now.addingTimeInterval(CodexSessionMonitorSchedule.minimumDelay))
    }

    func testRetentionMatchesTheMonitorFilter() {
        XCTAssertEqual(CodexSessionMonitorSchedule.retention(for: .running), 30 * 60)
        XCTAssertEqual(CodexSessionMonitorSchedule.retention(for: .completed), 2 * 60 * 60)
        XCTAssertEqual(CodexSessionMonitorSchedule.retention(for: .failed), 2 * 60 * 60)
    }
}
