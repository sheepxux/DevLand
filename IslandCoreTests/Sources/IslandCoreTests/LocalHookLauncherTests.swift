import Darwin
import Foundation
import XCTest
@testable import IslandCore

final class LocalHookLauncherTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-island-launcher-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var launcherURL: URL { LocalHookLauncher.url(homeDirectory: home) }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? Int) ?? -1
    }

    // MARK: - Template

    func testLauncherTemplateIsStaticAndRegistryDriven() {
        let script = LocalHooksInstaller.launcherScript()
        XCTAssertEqual(script, LocalHooksInstaller.launcherScript(), "the template has no per-call variables")
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.hasSuffix("exit 0\n"))

        // Every verified action route/event pair waits for the island; nothing else does.
        for descriptor in LocalAgentRegistry.all where descriptor.standalonePluginRenderer == nil {
            for event in descriptor.actionHookEvents {
                XCTAssertTrue(script.contains("\(descriptor.endpointPath)/\(event)"), "\(descriptor.source)/\(event)")
            }
            if !descriptor.usesTerminalFallback {
                XCTAssertTrue(script.contains("case \"$ROUTE\" in \(descriptor.endpointPath)"), descriptor.source)
            }
        }
        XCTAssertTrue(script.contains("/hooks/codex/PermissionRequest"))
        XCTAssertTrue(script.contains("/hooks/claude-code/PreToolUse"))
        XCTAssertFalse(script.contains("/hooks/codex/SessionStart"), "lifecycle events stay passive")

        // The protocol pieces the listener enforces, verbatim.
        XCTAssertTrue(script.contains("-H '\(LocalHooksInstaller.requestHeaderName): \(LocalHooksInstaller.requestHeaderValue)'"))
        XCTAssertTrue(script.contains("-H \"@\(LocalHookAuthorizationStore.shellHeaderFilePath)\""))
        for header in ["X-Dev-Island-Terminal-Bundle", "X-Dev-Island-Terminal-Program",
                       "X-Dev-Island-TTY", "X-Dev-Island-Tmux", "X-Dev-Island-Tmux-Pane"] {
            XCTAssertTrue(script.contains(header), header)
        }
        XCTAssertTrue(script.contains("/usr/bin/curl --noproxy 127.0.0.1 -sf -m \"$1\""), "absolute curl, no PATH lookup")
        XCTAssertTrue(script.contains("send \(LocalHooksInstaller.launcherActionTimeoutSeconds) 2>/dev/null || true"))
        XCTAssertTrue(script.contains("send \(LocalHooksInstaller.launcherPassiveTimeoutSeconds) >/dev/null 2>&1 || true"))
        XCTAssertFalse(script.contains(localHookTestAuthorization.headerValue))
        XCTAssertFalse(script.contains("7824"), "the port travels on the vendor line, never in the file")
    }

    func testShellPathIsQuotedAndUserIndependent() {
        XCTAssertEqual(
            LocalHookLauncher.shellPath,
            "\"${HOME}/Library/Application Support/island-app/bin/dev-island-hook\""
        )
        XCTAssertFalse(LocalHookLauncher.shellPath.contains(NSUserName()))
    }

    // MARK: - Install

    func testInstallCreatesPrivateLauncherAndIsIdempotent() throws {
        XCTAssertEqual(LocalHookLauncher.state(at: launcherURL), .missing)
        XCTAssertEqual(try LocalHookLauncher.ensureInstalled(at: launcherURL), .current)

        XCTAssertEqual(try mode(of: launcherURL), 0o700)
        XCTAssertEqual(try mode(of: launcherURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try Data(contentsOf: launcherURL), LocalHookLauncher.expectedScript)

        let firstIdentity = try FileManager.default.attributesOfItem(atPath: launcherURL.path)[.systemFileNumber] as? Int
        XCTAssertEqual(try LocalHookLauncher.ensureInstalled(at: launcherURL), .current)
        let secondIdentity = try FileManager.default.attributesOfItem(atPath: launcherURL.path)[.systemFileNumber] as? Int
        XCTAssertEqual(firstIdentity, secondIdentity, "a current launcher is never rewritten")
    }

    func testStaleLauncherIsRepairedInPlace() throws {
        try LocalHookLauncher.ensureInstalled(at: launcherURL)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcherURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherURL.path)
        XCTAssertEqual(LocalHookLauncher.state(at: launcherURL), .stale)

        XCTAssertEqual(try LocalHookLauncher.ensureInstalled(at: launcherURL), .current)
        XCTAssertEqual(try Data(contentsOf: launcherURL), LocalHookLauncher.expectedScript)
        XCTAssertEqual(try mode(of: launcherURL), 0o700)
    }

    func testUnsafeLaunchersAreReportedAndNeverReplaced() throws {
        try LocalHookLauncher.ensureInstalled(at: launcherURL)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)
        XCTAssertEqual(LocalHookLauncher.state(at: launcherURL), .unsafe)
        XCTAssertThrowsError(try LocalHookLauncher.ensureInstalled(at: launcherURL))
        XCTAssertEqual(try mode(of: launcherURL), 0o755, "an unsafe file is left exactly as found")
        XCTAssertThrowsError(try LocalHookLauncher.removeIfPresent(at: launcherURL))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherURL.path)

        let peer = home.appendingPathComponent("peer-link")
        try FileManager.default.linkItem(at: launcherURL, to: peer)
        XCTAssertEqual(LocalHookLauncher.state(at: launcherURL), .unsafe, "a second hard link")
        try FileManager.default.removeItem(at: peer)
        XCTAssertEqual(LocalHookLauncher.state(at: launcherURL), .current)

        try FileManager.default.removeItem(at: launcherURL)
        let elsewhere = home.appendingPathComponent("elsewhere.sh")
        try LocalHookLauncher.expectedScript.write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: launcherURL, withDestinationURL: elsewhere)
        XCTAssertEqual(LocalHookLauncher.state(at: launcherURL), .unsafe, "a symlink")
        XCTAssertThrowsError(try LocalHookLauncher.ensureInstalled(at: launcherURL))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: launcherURL.path),
            elsewhere.path,
            "the link is not followed or replaced"
        )
    }

    func testRemoveIfPresentDeletesOnlyASafeLauncher() throws {
        try LocalHookLauncher.removeIfPresent(at: launcherURL)
        XCTAssertEqual(LocalHookLauncher.state(at: launcherURL), .missing)
        try LocalHookLauncher.ensureInstalled(at: launcherURL)
        try LocalHookLauncher.removeIfPresent(at: launcherURL)
        XCTAssertEqual(LocalHookLauncher.state(at: launcherURL), .missing)
    }

    // MARK: - Execution

    private func availableLoopbackPort() throws -> Int {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fileDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.EADDRINUSE) }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fileDescriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw POSIXError(.EIO) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func runLauncher(
        arguments: [String],
        payload: Data,
        homeDirectory: URL
    ) throws -> (status: Int32, stdout: String, seconds: TimeInterval) {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeDirectory.path
        environment["PATH"] = "/usr/bin:/bin"
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(LocalHookLauncher.shellPath) \(arguments.joined(separator: " ")) || true"]
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        let started = Date()
        try process.run()
        input.fileHandleForWriting.write(payload)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: bytes, as: UTF8.self), Date().timeIntervalSince(started))
    }

    private func installAuthorizationFile(in homeDirectory: URL) throws {
        let file = homeDirectory.appendingPathComponent(LocalHookAuthorizationStore.relativeHeaderFilePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try localHookTestAuthorization.headerFileData.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func testLauncherFailsOpenWithoutAListener() throws {
        try installAuthorizationFile(in: home)
        try LocalHookLauncher.ensureInstalled(at: launcherURL)
        let closedPort = try availableLoopbackPort()

        let passive = try runLauncher(
            arguments: ["--route", "/hooks/codex", "--event", "SessionStart", "--port", "\(closedPort)"],
            payload: Data(#"{"hook_event_name":"SessionStart","session_id":"fail-open","cwd":"/tmp"}"#.utf8),
            homeDirectory: home
        )
        XCTAssertEqual(passive.status, 0)
        XCTAssertEqual(passive.stdout, "")
        XCTAssertLessThan(passive.seconds, 5)

        let action = try runLauncher(
            arguments: ["--route", "/hooks/codex", "--event", "PermissionRequest", "--port", "\(closedPort)"],
            payload: Data(#"{"hook_event_name":"PermissionRequest","session_id":"fail-open"}"#.utf8),
            homeDirectory: home
        )
        XCTAssertEqual(action.status, 0)
        XCTAssertEqual(action.stdout, "", "no listener means no decision text for the vendor")
    }

    func testLauncherRejectsMalformedArgumentsWithoutContactingAnything() throws {
        try installAuthorizationFile(in: home)
        try LocalHookLauncher.ensureInstalled(at: launcherURL)
        for arguments in [
            ["--route", "/hooks/", "--event", "SessionStart", "--port", "1"],
            ["--route", "/hooks/co dex", "--event", "SessionStart", "--port", "1"],
            ["--route", "/hooks/codex", "--event", "Session Start", "--port", "1"],
            ["--route", "/hooks/codex", "--event", "SessionStart", "--port", "80a"],
            ["--route", "../etc", "--event", "SessionStart", "--port", "1"],
            [],
        ] {
            let result = try runLauncher(arguments: arguments, payload: Data("{}".utf8), homeDirectory: home)
            XCTAssertEqual(result.status, 0, "\(arguments)")
            XCTAssertEqual(result.stdout, "", "\(arguments)")
            XCTAssertLessThan(result.seconds, 2, "\(arguments)")
        }
    }

    func testLauncherForwardsLifecycleEventsToTheListener() async throws {
        try installAuthorizationFile(in: home)
        try LocalHookLauncher.ensureInstalled(at: launcherURL)
        let port = try availableLoopbackPort()
        let server = makeLocalHookServer(port: port)
        let received = ReceivedEvents()

        await server.start(agents: [.codex]) { source, event in
            await received.record(source: source, sessionID: event.sessionId)
        }
        defer { Task { await server.stop() } }
        let readyDeadline = Date().addingTimeInterval(3)
        while await server.statusSnapshot() != .listening && Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let status = await server.statusSnapshot()
        XCTAssertEqual(status, .listening)

        let result = try runLauncher(
            arguments: ["--route", "/hooks/codex", "--event", "SessionStart", "--port", "\(port)"],
            payload: Data(#"{"hook_event_name":"SessionStart","session_id":"launcher-session","cwd":"/tmp/launcher"}"#.utf8),
            homeDirectory: home
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "", "lifecycle output is discarded")

        let deadline = Date().addingTimeInterval(2)
        while await received.events.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await received.events
        XCTAssertEqual(events.map(\.source), ["codex"])
        XCTAssertEqual(events.map(\.sessionID), ["launcher-session"])
        await server.stop()
    }
}

private actor ReceivedEvents {
    struct Event: Equatable { let source: String; let sessionID: String }
    private(set) var events: [Event] = []

    func record(source: String, sessionID: String) {
        events.append(Event(source: source, sessionID: sessionID))
    }
}
