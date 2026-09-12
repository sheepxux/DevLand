import Foundation
import XCTest
@testable import IslandCore

final class CodexSessionChangeSignalTests: XCTestCase {
    func testPendingSignalReturnsImmediatelyAndBurstsCoalesce() async {
        let signal = CodexSessionChangeSignal()
        await signal.signal()
        await signal.signal()
        await signal.signal()
        let first = await signal.wait(until: nil)
        XCTAssertEqual(first, .changed)
        // Three signals produced exactly one wakeup: the next wait blocks
        // until its deadline instead of returning another change.
        let second = await signal.wait(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(second, .deadline)
    }

    func testDeadlineWakesWithoutChanges() async {
        let signal = CodexSessionChangeSignal()
        let start = ContinuousClock.now
        let wake = await signal.wait(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(wake, .deadline)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(250))
    }

    func testPastDeadlineDoesNotSuspend() async {
        let signal = CodexSessionChangeSignal()
        let start = ContinuousClock.now
        let wake = await signal.wait(until: Date().addingTimeInterval(-1))
        XCTAssertEqual(wake, .deadline)
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(100))
    }

    func testChangeWakesBeforeDeadline() async throws {
        let signal = CodexSessionChangeSignal()
        let waiter = Task { await signal.wait(until: Date().addingTimeInterval(10)) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        await signal.signal()
        let wake = await waiter.value
        XCTAssertEqual(wake, .changed)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "the deadline timer must not be waited out")
    }

    func testCancellationReleasesAWaiterWithoutDeadline() async throws {
        let signal = CodexSessionChangeSignal()
        let waiter = Task { await signal.wait(until: nil) }
        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        let wake = await waiter.value
        XCTAssertEqual(wake, .cancelled)
    }

    func testCancelledTaskDoesNotWait() async {
        let signal = CodexSessionChangeSignal()
        let waiter = Task { () -> CodexSessionChangeSignal.Wake in
            try? await Task.sleep(for: .seconds(5))
            return await signal.wait(until: nil)
        }
        waiter.cancel()
        let wake = await waiter.value
        XCTAssertEqual(wake, .cancelled)
    }

    func testSignalAfterDeadlineIsKeptForTheNextWait() async {
        let signal = CodexSessionChangeSignal()
        let expired = await signal.wait(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(expired, .deadline)
        await signal.signal()
        let next = await signal.wait(until: Date().addingTimeInterval(5))
        XCTAssertEqual(next, .changed)
    }
}
