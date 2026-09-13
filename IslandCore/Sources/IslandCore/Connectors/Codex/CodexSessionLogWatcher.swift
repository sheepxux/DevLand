import CoreServices
import Darwin
import Foundation

/// One directory discovery stream plus bounded, content-free file watches.
///
/// Codex writes every rollout record under `sessions/YYYY/MM/DD/`, so
/// FSEvents discovers new sessions and directory changes, but may defer writes
/// until Codex closes its long-lived rollout descriptor. Vnode subscriptions
/// cover the monitor's exact candidates while those writers remain open. Neither
/// callback reads content or event paths. One event-triggered callback coalesces
/// changes using `coalescingLatency`; this watcher has no periodic timer.
///
/// FSEvents resolves the watched path when the stream is created, so a root
/// that does not exist yet is watched through its parent directory (`~/.codex`)
/// and the stream moves onto the root itself as soon as it appears. Nothing
/// above that parent is ever watched: on a Mac without Codex the watcher stays
/// silent until `refresh()` is called for another reason. A root that
/// disappears or is renamed arrives as a root-changed event and re-arms.
final class CodexSessionLogWatcher: @unchecked Sendable {
    static let coalescingLatency: TimeInterval = 1.0
    static let maximumFileWatches = 64

    struct FileTarget: Equatable, Sendable {
        let components: [String]
        let device: dev_t
        let inode: ino_t
    }

    private struct FileWatch {
        let target: FileTarget
        let source: DispatchSourceFileSystemObject
    }

    private let root: URL
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private let startStream: (FSEventStreamRef) -> Bool
    private let queue = DispatchQueue(label: "dev-island.codex.session-watcher", qos: .utility)
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private struct Target: Equatable {
        let path: String
        let device: dev_t
        let inode: ino_t
    }
    private var armedTarget: Target?
    private var fileWatches: [String: FileWatch] = [:]
    private var pendingChange: DispatchWorkItem?
    private var changeGeneration: UInt64 = 0
    private var stopped = false

    init(
        root: URL,
        latency: TimeInterval = CodexSessionLogWatcher.coalescingLatency,
        startStream: @escaping (FSEventStreamRef) -> Bool = FSEventStreamStart,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.root = root
        self.latency = latency
        self.startStream = startStream
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// Start delivering change notifications. Returns false when FSEvents
    /// refuses the subscription; the caller then reports monitoring as
    /// unavailable rather than falling back to polling.
    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        if stream != nil { return true }
        guard let target = watchTarget() else { return true }
        return arm(target)
    }

    /// Re-evaluate which directory to watch. Cheap when nothing moved; used
    /// after every read pass so a root that appeared while its parent was
    /// being watched — or after a nudge from a Hook — becomes the target.
    @discardableResult
    func refresh() -> Bool {
        lock.lock()
        let result = refreshLocked(force: false)
        lock.unlock()
        // Subscribe before the final scan so writes in the old stream's
        // teardown/re-arm gap cannot be left waiting for another event.
        if result.changed && result.available { enqueueChange() }
        return result.available
    }

    /// Bind only candidates discovered by the bounded log reader. Each final
    /// descriptor must identify the exact regular file that reader observed.
    /// Unchanged identities keep their existing subscription and descriptor.
    @discardableResult
    func updateFiles(_ targets: [FileTarget]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        var available = targets.count <= Self.maximumFileWatches
        var requested: [String: FileTarget] = [:]
        for target in targets.prefix(Self.maximumFileWatches) {
            guard Self.validComponents(target.components) else {
                available = false
                continue
            }
            let key = target.components.joined(separator: "/")
            if let previous = requested[key], previous != target {
                available = false
                continue
            }
            requested[key] = target
        }
        for key in Array(fileWatches.keys) where requested[key] != fileWatches[key]?.target {
            fileWatches.removeValue(forKey: key)?.source.cancel()
        }
        var installed = false
        for (key, target) in requested {
            if fileWatches[key]?.target == target { continue }
            guard let descriptor = openFileTarget(target) else {
                available = false
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib],
                queue: queue
            )
            source.setEventHandler { [weak self] in self?.fileChanged(key: key, target: target) }
            // This handler owns this exact fd. Closing on cancellation (rather
            // than in updateFiles) prevents a queued source from using a reused fd.
            source.setCancelHandler { Darwin.close(descriptor) }
            fileWatches[key] = FileWatch(target: target, source: source)
            source.activate()
            installed = true
        }
        // A write between the reader's snapshot and subscription is recovered
        // by one final scan after installation, even if no later write occurs.
        if installed { enqueueChangeLocked() }
        return available
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        changeGeneration &+= 1
        pendingChange?.cancel()
        pendingChange = nil
        fileWatches.values.forEach { $0.source.cancel() }
        fileWatches.removeAll()
        disarm()
    }

    // MARK: - Private

    private static func validComponents(_ components: [String]) -> Bool {
        (1...4).contains(components.count) && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." &&
                $0.utf8.count <= 255 && !$0.contains("/") && !$0.utf8.contains(0)
        }
    }

    /// Caller holds `lock`. Walk directory components through no-follow
    /// descriptors; opening the final file never grants content-read access.
    private func openFileTarget(_ target: FileTarget) -> Int32? {
        var directory = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directory >= 0 else { return nil }
        defer { Darwin.close(directory) }
        for component in target.components.dropLast() {
            let next = component.withCString {
                Darwin.openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { return nil }
            Darwin.close(directory)
            directory = next
        }
        guard let name = target.components.last else { return nil }
        let descriptor = name.withCString {
            Darwin.openat(directory, $0, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_dev == target.device, metadata.st_ino == target.inode else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    private func fileChanged(key: String, target: FileTarget) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, fileWatches[key]?.target == target else { return }
        enqueueChangeLocked()
    }

    private func enqueueChange() {
        lock.lock()
        defer { lock.unlock() }
        enqueueChangeLocked()
    }

    /// First event starts one window. Later events do not postpone it, so a
    /// continuous writer cannot defer its last notification indefinitely.
    private func enqueueChangeLocked() {
        guard !stopped, pendingChange == nil else { return }
        changeGeneration &+= 1
        let generation = changeGeneration
        let work = DispatchWorkItem { [weak self] in self?.deliverQueuedChange(generation) }
        pendingChange = work
        queue.asyncAfter(deadline: .now() + latency, execute: work)
    }

    private func deliverQueuedChange(_ generation: UInt64) {
        lock.lock()
        guard !stopped, generation == changeGeneration, pendingChange != nil else {
            lock.unlock()
            return
        }
        pendingChange = nil
        lock.unlock()
        onChange()
    }

    /// Reference-counted by the stream itself, so a callback that races
    /// `stop()` finds a released watcher instead of a dangling pointer.
    private final class Relay {
        weak var watcher: CodexSessionLogWatcher?
        init(_ watcher: CodexSessionLogWatcher) { self.watcher = watcher }
    }

    /// A nonexistent path cannot be used as an armed subscription: FSEvents
    /// may accept it without observing its later creation. Stay dormant when
    /// neither directory exists, then bind a real directory on refresh.
    private func watchTarget() -> Target? {
        if let target = directoryTarget(root) { return target }
        let parent = root.deletingLastPathComponent()
        return parent.path != root.path ? directoryTarget(parent) : nil
    }

    private func directoryTarget(_ url: URL) -> Target? {
        var metadata = stat()
        guard url.path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return Target(path: url.path, device: metadata.st_dev, inode: metadata.st_ino)
    }

    /// Caller holds `lock`. Failure leaves no stream and may be retried by a
    /// later refresh, without creating a timer or a self-triggered retry loop.
    private func refreshLocked(force: Bool) -> (available: Bool, changed: Bool) {
        guard !stopped else { return (false, false) }
        let target = watchTarget()
        guard force || target != armedTarget || (target != nil && stream == nil) else {
            return (true, false)
        }
        disarm()
        guard let target else { return (true, true) }
        return (arm(target), true)
    }

    /// Caller holds `lock`.
    private func arm(_ target: Target) -> Bool {
        let relay = Relay(self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(relay).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Relay>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Relay>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            nil,
            { _, info, count, _, eventFlags, _ in
                guard let info else { return }
                let relay = Unmanaged<Relay>.fromOpaque(info).takeUnretainedValue()
                var rootChanged = false
                for index in 0..<count
                where eventFlags[index] & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                    rootChanged = true
                }
                relay.watcher?.deliver(rootChanged: rootChanged)
            },
            &context,
            [target.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return false }
        withExtendedLifetime(relay) {}
        FSEventStreamSetDispatchQueue(created, queue)
        guard startStream(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        armedTarget = target
        return true
    }

    /// Caller holds `lock`.
    private func disarm() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        armedTarget = nil
    }

    /// Runs on `queue` from the stream callback.
    private func deliver(rootChanged: Bool) {
        lock.lock()
        let active = !stopped
        let indirect = armedTarget?.path != root.path
        lock.unlock()
        guard active else { return }
        if rootChanged || indirect {
            // Re-arm outside the callback that belongs to the old stream.
            queue.async { [weak self] in self?.refreshAfterEvent(force: rootChanged) }
        }
        enqueueChange()
    }

    private func refreshAfterEvent(force: Bool) {
        lock.lock()
        let result = refreshLocked(force: force)
        lock.unlock()
        // Also publish a failed re-arm: TaskStore must stop claiming that
        // change notifications are available after losing its subscription.
        if result.changed { enqueueChange() }
    }
}
