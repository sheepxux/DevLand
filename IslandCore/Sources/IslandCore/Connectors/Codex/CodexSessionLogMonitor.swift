import Darwin
import Foundation

public enum CodexSessionMonitorStatus: Equatable, Sendable {
    case stopped
    case notFound
    case available
    case unavailable
}

/// Read-only, bounded discovery of recent desktop/CLI sessions. Hooks remain
/// the authority for approval requests; a transcript never creates an action.
/// The caller owns polling cadence and cancellation. No file handles survive
/// a poll, so replacing, archiving or deleting a rollout removes its snapshot.
public actor CodexSessionLogMonitor {
    public static var defaultRoot: URL {
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let home = configured.flatMap { value -> URL? in
            guard value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: value, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return home.appendingPathComponent("sessions", isDirectory: true)
    }

    public private(set) var status: CodexSessionMonitorStatus = .notFound

    private let root: URL
    private let limits: Limits
    private var files: [String: FileState] = [:]
    private var candidateCache: [String: Candidate] = [:]
    private var lastFullDiscovery: Date?
    private var fullDiscoveryUnavailable = false

    public init(root: URL = CodexSessionLogMonitor.defaultRoot) {
        self.root = root
        self.limits = Limits()
    }

    /// Smaller limits let tests exercise the production bounds without large
    /// fixtures. These controls are intentionally not exposed as app settings.
    init(root: URL, limits: Limits) {
        self.root = root
        self.limits = limits
    }

    struct Limits: Sendable {
        var maximumFiles = 64
        var maximumEntries = 8_192
        var headerBytes = 256 * 1_024 + 1
        var tailBytes = 512 * 1_024
        var lineBytes = 256 * 1_024
        var pollBytes = 2 * 1_024 * 1_024
    }

    /// A stable snapshot, not a stream of new events: timestamps always come
    /// from Codex. Old active tasks expire after 30 minutes without an event;
    /// ended turns are retained for two hours and never resurrected by mtime.
    func poll(now: Date = .now) -> [CodexSessionObservation] {
        guard !Task.isCancelled else { return [] }
        guard root.isFileURL, root.path.hasPrefix("/") else {
            status = .unavailable
            files.removeAll()
            candidateCache.removeAll()
            lastFullDiscovery = nil
            return []
        }
        let rootFD = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard rootFD >= 0 else {
            status = errno == ENOENT ? .notFound : .unavailable
            files.removeAll()
            candidateCache.removeAll()
            lastFullDiscovery = nil
            return []
        }
        defer { Darwin.close(rootFD) }
        status = .available

        let candidates = discover(rootFD: rootFD, now: now)
        let names = Set(candidates.map(\.key))
        files = files.filter { names.contains($0.key) }
        var remainingBytes = limits.pollBytes
        for candidate in candidates {
            guard !Task.isCancelled else { return [] }
            do {
                if let state = try read(candidate, rootFD: rootFD, now: now, budget: &remainingBytes) {
                    files[candidate.key] = state
                    candidateCache[candidate.key] = Candidate(folder: candidate.folder, name: candidate.name, metadata: state.metadata)
                }
            } catch {
                // Never preserve a live-looking task after its file becomes
                // unreadable or changes identity during this poll.
                files.removeValue(forKey: candidate.key)
                candidateCache.removeValue(forKey: candidate.key)
                if (error as? ReadError) != .removed { status = .unavailable }
            }
        }

        var observations: [String: CodexSessionObservation] = [:]
        for key in files.keys.sorted() {
            guard let observation = files[key]?.parser.observation,
                  observation.task.status != .waiting else { continue }
            let age = now.timeIntervalSince(observation.task.updatedAt)
            let maximumAge: TimeInterval = observation.task.status == .running ? 30 * 60 : 2 * 60 * 60
            // A malformed far-future timestamp must not create an immortal row.
            guard age >= -5 * 60, age <= maximumAge else { continue }
            if let existing = observations[observation.task.id],
               existing.task.updatedAt >= observation.task.updatedAt { continue }
            observations[observation.task.id] = observation
        }
        return observations.values.sorted {
            if $0.task.updatedAt != $1.task.updatedAt { return $0.task.updatedAt > $1.task.updatedAt }
            return $0.task.id < $1.task.id
        }
    }

    private struct Candidate {
        let folder: [String]
        let name: String
        let metadata: Metadata
        var key: String { (folder + [name]).joined(separator: "/") }
    }

    private struct Metadata: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
        }
        func isSameFile(as other: Metadata) -> Bool { device == other.device && inode == other.inode }
    }

    private struct FileState {
        var metadata: Metadata
        var parser = CodexSessionLogParser()
        var offset: off_t = 0
        var prefix = Data()
        var partialLine = Data()
        var droppingLine = false
    }

    /// Refresh recent dates on each poll and perform a bounded discovery of
    /// the date tree every ten seconds. Codex keeps a resumed conversation in
    /// its original creation-date folder, so recent directories alone miss it.
    /// Only YYYY/MM/DD paths are traversed; no arbitrary recursive home scan.
    private func discover(rootFD: Int32, now: Date) -> [Candidate] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var entries = 0
        let fullDiscovery = lastFullDiscovery.map { now.timeIntervalSince($0) >= 10 || now < $0 } ?? true
        var discovered: [Candidate] = []
        if fullDiscovery {
            for year in directoryNames(rootFD: rootFD, components: [], digits: 4, range: 1...9_999, entries: &entries) {
                for month in directoryNames(rootFD: rootFD, components: [year], digits: 2, range: 1...12, entries: &entries) {
                    for day in directoryNames(rootFD: rootFD, components: [year, month], digits: 2, range: 1...31, entries: &entries) {
                        let parts = DateComponents(year: Int(year), month: Int(month), day: Int(day))
                        guard let date = calendar.date(from: parts) else { continue }
                        let actual = calendar.dateComponents([.year, .month, .day], from: date)
                        guard actual.year == parts.year, actual.month == parts.month, actual.day == parts.day else { continue }
                        scanDirectory(rootFD: rootFD, folder: [year, month, day], entries: &entries, candidates: &discovered)
                    }
                }
            }
            candidateCache = Dictionary(uniqueKeysWithValues: discovered.map { ($0.key, $0) })
            lastFullDiscovery = now
            fullDiscoveryUnavailable = status == .unavailable
        } else {
            for daysAgo in 0..<3 {
                guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { continue }
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                let folder = [String(format: "%04d", parts.year!), String(format: "%02d", parts.month!), String(format: "%02d", parts.day!)]
                candidateCache = candidateCache.filter { $0.value.folder != folder }
                scanDirectory(rootFD: rootFD, folder: folder, entries: &entries, candidates: &discovered)
            }
            for candidate in discovered { candidateCache[candidate.key] = candidate }
            if fullDiscoveryUnavailable { status = .unavailable }
        }
        let candidates = Array(candidateCache.values.sorted(by: candidatePrecedes).prefix(limits.maximumFiles))
        candidateCache = Dictionary(uniqueKeysWithValues: candidates.map { ($0.key, $0) })
        return candidates
    }

    private func directoryNames(
        rootFD: Int32, components: [String], digits: Int, range: ClosedRange<Int>, entries: inout Int
    ) -> [String] {
        var names: [String] = []
        enumerate(rootFD: rootFD, components: components, entries: &entries) { name, metadata in
            guard name.utf8.count == digits,
                  name.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let number = Int(name), range.contains(number),
                  (metadata.st_mode & S_IFMT) == S_IFDIR else { return }
            names.append(name)
        }
        return names.sorted(by: >)
    }

    private func scanDirectory(rootFD: Int32, folder: [String], entries: inout Int, candidates: inout [Candidate]) {
        enumerate(rootFD: rootFD, components: folder, entries: &entries) { name, metadata in
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
                  (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_size >= 0 else { return }
            candidates.append(Candidate(folder: folder, name: name, metadata: Metadata(metadata)))
            candidates.sort(by: candidatePrecedes)
            if candidates.count > limits.maximumFiles { candidates.removeLast() }
        }
    }

    /// readdir avoids materializing an unbounded directory listing. fstatat
    /// does not follow links; openat also rechecks each component before use.
    private func enumerate(
        rootFD: Int32, components: [String], entries: inout Int, visit: (String, stat) -> Void
    ) {
        guard !Task.isCancelled else { return }
        guard entries < limits.maximumEntries else { status = .unavailable; return }
        guard let directory = openDirectory(rootFD: rootFD, components: components) else { return }
        guard let stream = Darwin.fdopendir(directory) else {
            Darwin.close(directory)
            status = .unavailable
            return
        }
        defer { Darwin.closedir(stream) }
        while entries < limits.maximumEntries, !Task.isCancelled, let entry = Darwin.readdir(stream) {
            entries += 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            var metadata = stat()
            guard name.withCString({ Darwin.fstatat(directory, $0, &metadata, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                if errno != ENOENT { status = .unavailable }
                continue
            }
            visit(name, metadata)
        }
        if entries >= limits.maximumEntries { status = .unavailable }
    }

    private func candidatePrecedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.metadata.modifiedSeconds != rhs.metadata.modifiedSeconds {
            return lhs.metadata.modifiedSeconds > rhs.metadata.modifiedSeconds
        }
        if lhs.metadata.modifiedNanoseconds != rhs.metadata.modifiedNanoseconds {
            return lhs.metadata.modifiedNanoseconds > rhs.metadata.modifiedNanoseconds
        }
        return lhs.key < rhs.key
    }

    private func openDirectory(rootFD: Int32, components: [String]) -> Int32? {
        var descriptor = Darwin.dup(rootFD)
        guard descriptor >= 0 else { status = .unavailable; return nil }
        for component in components {
            let next = component.withCString {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            let failure = errno
            Darwin.close(descriptor)
            guard next >= 0 else {
                if failure != ENOENT { status = .unavailable }
                return nil
            }
            descriptor = next
        }
        return descriptor
    }

    private enum ReadError: Error, Equatable { case unavailable, removed }

    private func read(_ candidate: Candidate, rootFD: Int32, now: Date, budget: inout Int) throws -> FileState? {
        guard let directory = openDirectory(rootFD: rootFD, components: candidate.folder) else {
            throw ReadError.unavailable
        }
        defer { Darwin.close(directory) }
        let descriptor = candidate.name.withCString {
            Darwin.openat(directory, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw errno == ENOENT ? ReadError.removed : ReadError.unavailable }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG, information.st_size >= 0 else {
            throw ReadError.unavailable
        }
        let metadata = Metadata(information)
        guard metadata.isSameFile(as: candidate.metadata) else { throw ReadError.unavailable }
        var previous = files[candidate.key]
        if let state = previous {
            if !metadata.isSameFile(as: state.metadata) || metadata.size < state.offset ||
                (metadata.size == state.metadata.size && metadata != state.metadata) {
                previous = nil
            } else if metadata == state.metadata && state.offset == metadata.size {
                return state
            } else if !state.prefix.isEmpty {
                guard budget >= state.prefix.count else { return nil }
                let prefix = try readBytes(descriptor, offset: 0, count: state.prefix.count, budget: &budget)
                if prefix != state.prefix { previous = nil }
            }
        }

        let isNew = previous == nil
        var state = previous ?? FileState(metadata: metadata)
        if isNew {
            files.removeValue(forKey: candidate.key)
            let headerLength = metadata.size > off_t(limits.tailBytes) ? min(Int(metadata.size), limits.headerBytes) : 0
            let tailLength = min(metadata.size, off_t(limits.tailBytes))
            // Bootstrap atomically within this poll's budget, so an exhausted
            // budget cannot strand a parser without its session metadata.
            guard budget >= headerLength + Int(tailLength) else { return nil }
            if headerLength > 0 {
                var header = Data()
                while header.count < headerLength && !header.contains(0x0A) {
                    let chunk = try readBytes(descriptor, offset: off_t(header.count), count: min(64 * 1_024, headerLength - header.count), budget: &budget)
                    header.append(chunk)
                }
                state.prefix = Data(header.prefix(128))
                if let end = header.firstIndex(of: 0x0A), end <= limits.lineBytes {
                    state.parser.consume(line: Data(header[..<end]), referenceDate: now)
                }
                state.offset = metadata.size - tailLength
                state.droppingLine = true
            }
        }
        // If the producer wrote a huge burst, jump to a bounded suffix while
        // preserving known metadata. Never parse a partial record at the jump.
        if metadata.size - state.offset > off_t(limits.tailBytes) {
            state.offset = metadata.size - off_t(limits.tailBytes)
            state.parser.resetAfterSkippedRecords()
            state.partialLine.removeAll(keepingCapacity: false)
            state.droppingLine = true
        }
        var fileBudget = limits.tailBytes
        while state.offset < metadata.size && budget > 0 && fileBudget > 0 {
            guard !Task.isCancelled else { return nil }
            let count = min(Int(metadata.size - state.offset), min(64 * 1_024, min(budget, fileBudget)))
            let bytes = try readBytes(descriptor, offset: state.offset, count: count, budget: &budget)
            if state.offset == 0 { state.prefix = Data(bytes.prefix(128)) }
            consume(bytes, state: &state, now: now)
            state.offset += off_t(bytes.count)
            fileBudget -= bytes.count
        }
        state.metadata = metadata
        return state
    }

    private func readBytes(_ descriptor: Int32, offset: off_t, count: Int, budget: inout Int) throws -> Data {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            guard !Task.isCancelled else { throw ReadError.unavailable }
            let result = bytes.withUnsafeMutableBytes {
                Darwin.pread(descriptor, $0.baseAddress!.advanced(by: total), count - total, offset + off_t(total))
            }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw ReadError.unavailable }
            total += result
            budget -= result
        }
        return Data(bytes)
    }

    private func consume(_ bytes: Data, state: inout FileState, now: Date) {
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let newline = bytes[start...].firstIndex(of: 0x0A)
            let end = newline ?? bytes.endIndex
            if !state.droppingLine {
                if state.partialLine.count + end - start <= limits.lineBytes {
                    state.partialLine.append(contentsOf: bytes[start..<end])
                } else {
                    state.partialLine.removeAll(keepingCapacity: false)
                    state.droppingLine = true
                }
            }
            guard let newline else { return }
            if !state.droppingLine && !state.partialLine.isEmpty {
                state.parser.consume(line: state.partialLine, referenceDate: now)
            }
            state.partialLine.removeAll(keepingCapacity: true)
            state.droppingLine = false
            start = newline + 1
        }
    }
}
