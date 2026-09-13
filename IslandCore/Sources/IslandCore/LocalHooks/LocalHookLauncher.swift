import Darwin
import Foundation

/// The one executable every command-based Hook line points at.
///
/// Vendors such as Codex trust a Hook by the hash of its complete definition,
/// so the definition must never change once the user has reviewed it. The
/// launcher keeps every moving part — listener port, protocol header, private
/// authorization file, terminal hints, timeouts, fail-open redirects — inside a
/// file Dev Island owns, hash-verifies and repairs itself. The vendor config
/// line is therefore identical for every user and every Dev Island version:
///
///     "${HOME}/Library/Application Support/island-app/bin/dev-island-hook" \
///         --route /hooks/<source> --event <Event> --port 7824 || true
///
/// The launcher is a static POSIX `sh` script rendered from the registry (see
/// `LocalHooksInstaller.launcherScript`). It is installed as a current-user,
/// single-link, `0700` regular file; anything else is reported as unsafe and
/// left untouched.
public enum LocalHookLauncher {
    public static let relativeDirectoryPath = "Library/Application Support/island-app/bin"
    public static let fileName = "dev-island-hook"
    public static let relativePath = "\(relativeDirectoryPath)/\(fileName)"
    /// Quoted for the space in "Application Support"; expanded by the vendor's
    /// shell, so the same bytes serve every user.
    public static let shellPath = "\"${HOME}/\(relativePath)\""
    static let permissions = 0o700
    static let maximumBytes = 64 * 1_024

    public enum State: Equatable, Sendable {
        /// Present with the exact expected bytes, ownership and mode.
        case current
        /// Present and safe, but its bytes differ from the current template.
        case stale
        case missing
        /// A link, foreign owner, wrong mode, extra hard link, or oversized
        /// file. Never repaired automatically.
        case unsafe
    }

    public enum LauncherError: Error, Equatable {
        case unsafeLauncher
    }

    public static func url(homeDirectory: URL? = nil) -> URL {
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(relativePath, isDirectory: false)
    }

    /// The bytes every install writes and every check compares against.
    public static var expectedScript: Data {
        Data(LocalHooksInstaller.launcherScript().utf8)
    }

    public static func state(at url: URL? = nil) -> State {
        let target = url ?? self.url()
        var information = stat()
        let status = target.path.withCString { lstat($0, &information) }
        if status != 0 {
            return errno == ENOENT ? .missing : .unsafe
        }
        guard (information.st_mode & S_IFMT) == S_IFREG,
              information.st_nlink == 1,
              information.st_uid == geteuid(),
              (information.st_mode & 0o777) == mode_t(permissions),
              information.st_size >= 0,
              information.st_size <= off_t(maximumBytes) else {
            return .unsafe
        }
        guard let bytes = boundedContents(of: target, expectedSize: information.st_size) else {
            return .unsafe
        }
        return bytes == expectedScript ? .current : .stale
    }

    /// Write the current template when it is missing or stale. Idempotent:
    /// a current launcher is never rewritten, so a reviewed file keeps its
    /// timestamps. An unsafe path is refused rather than replaced.
    @discardableResult
    public static func ensureInstalled(at url: URL? = nil) throws -> State {
        let target = url ?? self.url()
        switch state(at: target) {
        case .current:
            return .current
        case .unsafe:
            throw LauncherError.unsafeLauncher
        case .missing:
            try ManagedConfigFile.replace(
                expectedScript,
                at: target,
                expecting: .absent,
                permissions: permissions,
                maximumBytes: maximumBytes
            )
        case .stale:
            let current = try ManagedConfigFile.snapshotIfExists(at: target, maximumBytes: maximumBytes)
            try ManagedConfigFile.replace(
                expectedScript,
                at: target,
                expecting: current.map { .snapshot($0) } ?? .absent,
                permissions: permissions,
                maximumBytes: maximumBytes
            )
        }
        let installed = state(at: target)
        guard installed == .current else { throw LauncherError.unsafeLauncher }
        return installed
    }

    /// Best-effort repair used by the listener's serve loop. It never throws,
    /// never logs a path, and never blocks the listener: a Hook that cannot
    /// find its launcher fails open exactly like a stopped Dev Island.
    public static func selfHeal() {
        _ = try? ensureInstalled()
    }

    /// Remove the launcher when no Agent configuration references it any more.
    public static func removeIfPresent(at url: URL? = nil) throws {
        let target = url ?? self.url()
        switch state(at: target) {
        case .missing:
            return
        case .unsafe:
            throw LauncherError.unsafeLauncher
        case .current, .stale:
            guard let current = try ManagedConfigFile.snapshotIfExists(
                at: target,
                maximumBytes: maximumBytes
            ) else { return }
            try ManagedConfigFile.remove(at: target, expecting: current)
        }
    }

    private static func boundedContents(of url: URL, expectedSize: off_t) -> Data? {
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_size == expectedSize else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(expectedSize))
        var total = 0
        while total < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(descriptor, buffer.baseAddress?.advanced(by: total), buffer.count - total, off_t(total))
            }
            if count <= 0 { return nil }
            total += count
        }
        return Data(bytes)
    }
}
