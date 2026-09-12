import CoreServices
import Darwin
import Foundation
import XCTest
@testable import IslandCore

/// Real directory and vnode subscriptions on a temporary tree. Latency is
/// shortened while persistent writers model the production rollout lifecycle.
final class CodexSessionLogWatcherTests: XCTestCase {
    private var temporary: URL!
    private var root: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSessionWatcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        root = temporary.appendingPathComponent("sessions", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private final class ChangeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func bump() { lock.lock(); value += 1; lock.unlock() }
        func waitUntil(atLeast target: Int, timeout: TimeInterval = 5) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(timeout)
            while count < target {
                if ContinuousClock.now >= deadline { return false }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return true
        }
    }

    private func makeWatcher(_ counter: ChangeCounter, root: URL? = nil) -> CodexSessionLogWatcher {
        CodexSessionLogWatcher(root: root ?? self.root, latency: 0.1) { counter.bump() }
    }

    private func writeRollout(_ name: String, in day: String = "2026/09/11") throws -> URL {
        let directory = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-\(name).jsonl")
        try Data("{}\n".utf8).write(to: file)
        return file
    }

    private func fileTarget(_ file: URL, components: [String]? = nil) throws -> CodexSessionLogWatcher.FileTarget {
        var metadata = stat()
        guard file.path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let relative = String(file.path.dropFirst(root.path.count + 1))
        return CodexSessionLogWatcher.FileTarget(
            components: components ?? relative.split(separator: "/").map(String.init),
            device: metadata.st_dev, inode: metadata.st_ino
        )
    }

    func testAppendInsideExistingRootNotifies() async throws {
        let file = try writeRollout("one")
        let counter = ChangeCounter()
        let watcher = makeWatcher(counter)
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        // Settle any event from the setup writes before measuring.
        try await Task.sleep(for: .milliseconds(400))
        let before = counter.count

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\"}\n".utf8))
        try handle.close()
        let notified = await counter.waitUntil(atLeast: before + 1)
        XCTAssertTrue(notified, "an appended record must wake the monitor")
    }

    func testSuccessiveAppendsNotifyWhileTheWriterRemainsOpen() async throws {
        let file = try writeRollout("open-writer")
        // Codex retains its rollout writer across turns, including while the
        // island subscribes. Neither write below may depend on closing this fd.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let counter = ChangeCounter()
        let watcher = makeWatcher(counter)
        XCTAssertTrue(watcher.start())
        defer {
            watcher.stop()
            try? handle.close()
        }
        XCTAssertTrue(watcher.updateFiles([try fileTarget(file)]))
        try await Task.sleep(for: .milliseconds(400))

        let beforeFirstAppend = counter.count
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n".utf8))
        try handle.synchronize()
        let firstNotified = await counter.waitUntil(atLeast: beforeFirstAppend + 1)
        XCTAssertTrue(firstNotified, "the first append must notify before the persistent writer is closed")

        // Let the first coalescing window settle before establishing the second
        // baseline. A delayed first callback must not count as the next turn.
        try await Task.sleep(for: .milliseconds(400))
        let beforeSecondAppend = counter.count
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n".utf8))
        try handle.synchronize()
        let secondNotified = await counter.waitUntil(atLeast: beforeSecondAppend + 1)
        XCTAssertTrue(secondNotified, "a later append must notify independently while the same writer remains open")
    }

    func testUnchangedFileTargetsDoNotScheduleIdleReads() async throws {
        let file = try writeRollout("unchanged")
        let target = try fileTarget(file)
        let counter = ChangeCounter()
        // Isolate vnode notifications from directory discovery in this test.
        let watcher = makeWatcher(counter)
        defer { watcher.stop() }
        XCTAssertTrue(watcher.updateFiles([target]))
        let installed = await counter.waitUntil(atLeast: 1)
        XCTAssertTrue(installed, "new subscriptions require a final scan")
        try await Task.sleep(for: .milliseconds(250))
        let before = counter.count
        for _ in 0..<10 { XCTAssertTrue(watcher.updateFiles([target])) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counter.count, before, "the scan must not resubscribe and trigger itself forever")
    }

    func testReplacingAFileMovesTheWatchToTheNewIdentity() async throws {
        let file = try writeRollout("replacement")
        let oldTarget = try fileTarget(file)
        let oldWriter = try FileHandle(forWritingTo: file)
        try oldWriter.seekToEnd()
        let counter = ChangeCounter()
        let watcher = makeWatcher(counter)
        defer {
            watcher.stop()
            try? oldWriter.close()
        }
        XCTAssertTrue(watcher.updateFiles([oldTarget]))
        let installed = await counter.waitUntil(atLeast: 1)
        XCTAssertTrue(installed)

        try FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent("retired.jsonl"))
        try Data("{}\n".utf8).write(to: file)
        let replacementTarget = try fileTarget(file)
        XCTAssertNotEqual(replacementTarget.inode, oldTarget.inode)
        XCTAssertTrue(watcher.updateFiles([replacementTarget]))
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try await Task.sleep(for: .milliseconds(400))
        let afterReplacement = counter.count

        try oldWriter.write(contentsOf: Data("{\"retired\":true}\n".utf8))
        try oldWriter.synchronize()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counter.count, afterReplacement, "a cancelled old source must not report changes")

        try writer.write(contentsOf: Data("{\"replacement\":true}\n".utf8))
        try writer.synchronize()
        let notified = await counter.waitUntil(atLeast: afterReplacement + 1)
        XCTAssertTrue(notified, "closing the retired subscription must not close or invalidate its replacement")
    }

    func testFileWatchesRejectMismatchedIdentityAndSymlinkTraversal() async throws {
        let file = try writeRollout("safe")
        let target = try fileTarget(file)
        let counter = ChangeCounter()
        let watcher = makeWatcher(counter)
        defer { watcher.stop() }
        XCTAssertFalse(watcher.updateFiles([
            .init(components: target.components, device: target.device, inode: target.inode &+ 1)
        ]))

        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let externalFile = outside.appendingPathComponent("rollout-external.jsonl")
        try Data("{}\n".utf8).write(to: externalFile)
        let leaf = file.deletingLastPathComponent().appendingPathComponent("rollout-link.jsonl")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: externalFile)
        XCTAssertFalse(watcher.updateFiles([
            try fileTarget(externalFile, components: ["2026", "09", "11", "rollout-link.jsonl"])
        ]))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("2025"), withDestinationURL: outside)
        XCTAssertFalse(watcher.updateFiles([
            try fileTarget(externalFile, components: ["2025", "rollout-external.jsonl"])
        ]))
        XCTAssertFalse(watcher.updateFiles([
            try fileTarget(externalFile, components: ["..", "outside", "rollout-external.jsonl"])
        ]))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(counter.count, 0, "rejected targets must not create subscriptions or retry callbacks")
    }

    func testNewDayDirectoryAndAtomicWriteNotify() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let counter = ChangeCounter()
        let watcher = makeWatcher(counter)
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(400))
        let before = counter.count

        let directory = root.appendingPathComponent("2026/09/12", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: directory.appendingPathComponent("rollout-two.jsonl"), options: .atomic)
        let notified = await counter.waitUntil(atLeast: before + 1)
        XCTAssertTrue(notified)
    }

    func testRootCreatedLaterIsPickedUpAndItsContentsThenNotify() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let counter = ChangeCounter()
        let watcher = makeWatcher(counter)
        XCTAssertTrue(watcher.start(), "a missing root is watched through its parent")
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        _ = try writeRollout("one")
        let rootAppeared = await counter.waitUntil(atLeast: 1)
        XCTAssertTrue(rootAppeared, "creating the root must wake the monitor")

        // The stream was resolved before the root existed; after re-arming,
        // changes inside the new root must still arrive.
        try await Task.sleep(for: .milliseconds(500))
        let settled = counter.count
        let file = try writeRollout("two")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()
        let contentNotified = await counter.waitUntil(atLeast: settled + 1)
        XCTAssertTrue(contentNotified, "the re-armed stream must cover the new root")
    }

    func testDeeperMissingChainNeedsARefreshAndThenNotifies() async throws {
        // Nothing above the root's parent is watched, so a Mac without a
        // `.codex` directory costs no wakeups; a later refresh (Hook nudge,
        // toggle, relaunch) moves the subscription onto the new root.
        let deep = temporary.appendingPathComponent("missing/.codex/sessions", isDirectory: true)
        let counter = ChangeCounter()
        let watcher = makeWatcher(counter, root: deep)
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        let day = deep.appendingPathComponent("2026/09/11", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(600))
        let beforeRefresh = counter.count

        watcher.refresh()
        try await Task.sleep(for: .milliseconds(200))
        try Data("{}\n".utf8).write(to: day.appendingPathComponent("rollout-one.jsonl"))
        let notified = await counter.waitUntil(atLeast: beforeRefresh + 1)
        XCTAssertTrue(notified, "after a refresh the new root must be watched")
    }

    func testRefreshIsANoOpWhileTheRootIsAlreadyWatched() async throws {
        let file = try writeRollout("one")
        let counter = ChangeCounter()
        let watcher = makeWatcher(counter)
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(400))
        for _ in 0..<5 { watcher.refresh() }
        let before = counter.count

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()
        let notified = await counter.waitUntil(atLeast: before + 1)
        XCTAssertTrue(notified, "repeated refreshes must not drop the subscription")
    }

    func testRootRemovalNotifies() async throws {
        _ = try writeRollout("one")
        let counter = ChangeCounter()
        let watcher = makeWatcher(counter)
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(400))
        let before = counter.count

        try FileManager.default.removeItem(at: root)
        let notified = await counter.waitUntil(atLeast: before + 1)
        XCTAssertTrue(notified, "deleting the sessions tree must clear the snapshot promptly")
    }

    func testStopSuppressesLaterNotificationsAndIsIdempotent() async throws {
        let file = try writeRollout("one")
        let counter = ChangeCounter()
        let watcher = makeWatcher(counter)
        XCTAssertTrue(watcher.start())
        XCTAssertTrue(watcher.start(), "a second start is a no-op")
        XCTAssertTrue(watcher.updateFiles([try fileTarget(file)]))
        watcher.stop()
        watcher.stop()
        XCTAssertFalse(watcher.start(), "a stopped watcher never re-arms")
        XCTAssertFalse(watcher.updateFiles([try fileTarget(file)]))

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(counter.count, 0)
    }

    func testWatcherDeallocatesWhileStreamIsArmed() async throws {
        let file = try writeRollout("one")
        let counter = ChangeCounter()
        weak var released: CodexSessionLogWatcher?
        do {
            let watcher = makeWatcher(counter)
            XCTAssertTrue(watcher.start())
            XCTAssertTrue(watcher.updateFiles([try fileTarget(file)]))
            released = watcher
        }
        XCTAssertNil(released, "the stream's relay must not retain the watcher")
    }

    func testFailedSubscriptionCanRecoverOnRefreshWithoutRetryLoop() async throws {
        let file = try writeRollout("one")
        let counter = ChangeCounter()
        let attempts = ChangeCounter()
        let watcher = CodexSessionLogWatcher(root: root, latency: 0.1, startStream: { stream in
            attempts.bump()
            return attempts.count > 1 && FSEventStreamStart(stream)
        }) { counter.bump() }
        defer { watcher.stop() }
        XCTAssertFalse(watcher.start())
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(attempts.count, 1, "failed subscription must not create a retry timer")
        XCTAssertEqual(counter.count, 0)
        XCTAssertTrue(watcher.refresh(), "an explicit refresh can recover a missing stream")
        let refreshed = await counter.waitUntil(atLeast: 1)
        XCTAssertTrue(refreshed, "re-arming must request a scan after subscription")
        try await Task.sleep(for: .milliseconds(300))
        let settled = counter.count
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()
        let notified = await counter.waitUntil(atLeast: settled + 1)
        XCTAssertTrue(notified)
        watcher.stop()
        XCTAssertFalse(watcher.refresh(), "shutdown cannot be undone by refresh")
    }

    func testRearmFailureIsReportedAndCanRecover() async throws {
        let deep = temporary.appendingPathComponent("missing/.codex/sessions", isDirectory: true)
        let counter = ChangeCounter()
        let attempts = ChangeCounter()
        let watcher = CodexSessionLogWatcher(root: deep, latency: 0.1, startStream: { stream in
            attempts.bump()
            return attempts.count > 1 && FSEventStreamStart(stream)
        }) { counter.bump() }
        defer { watcher.stop() }
        XCTAssertTrue(watcher.start(), "missing parent is dormant, without a fake subscription")
        XCTAssertEqual(attempts.count, 0)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        XCTAssertFalse(watcher.refresh(), "failed arm after directory creation must be visible")
        XCTAssertEqual(counter.count, 0, "failed re-arm must not signal its own endless retry")
        XCTAssertTrue(watcher.refresh())
        let refreshed = await counter.waitUntil(atLeast: 1)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(counter.count, 1, "successful subscription must trigger the final scan")
    }
}
