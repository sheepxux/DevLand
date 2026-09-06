import Foundation
import XCTest
@testable import IslandCore

final class CodexHookAuthorizationTests: XCTestCase {
    func testReviewNeverWritesAndOnlyIncludesExactDevIslandDefinitions() throws {
        let fixture = Fixture()
        let review = try fixture.service.review()
        XCTAssertEqual(review.entries.map(\.eventName), LocalAgentDescriptor.codex.hookEvents)
        XCTAssertFalse(review.isAlreadyAuthorized)
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testExplicitAuthorizationUsesVendorKeysAndHashesWithVersionGuardThenVerifies() throws {
        let fixture = Fixture()
        let review = try fixture.service.review()
        try fixture.service.authorize(review)
        let write = try XCTUnwrap(fixture.writes.first)
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertEqual(write["filePath"] as? String, Fixture.configPath)
        XCTAssertEqual(write["expectedVersion"] as? String, "version-1")
        XCTAssertEqual(write["reloadUserConfig"] as? Bool, true)
        let edits = try XCTUnwrap(write["edits"] as? [[String: Any]])
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0]["keyPath"] as? String, "hooks.state")
        XCTAssertEqual(edits[0]["mergeStrategy"] as? String, "upsert")
        let updates = try XCTUnwrap(edits[0]["value"] as? [String: [String: String]])
        XCTAssertEqual(Set(updates.keys), Set(review.entries.map(\.key)))
        for entry in review.entries {
            XCTAssertEqual(updates[entry.key], ["trusted_hash": entry.currentHash])
        }
        XCTAssertNil(updates["vibe-island"], "Unrelated hooks must not be written")
        XCTAssertGreaterThanOrEqual(fixture.hookReads, 3, "Re-read before and after the write")
    }

    func testChangedHashCommandOrConfigurationRequiresAnotherReviewWithoutWriting() throws {
        for change in ["hash", "command", "config"] {
            let fixture = Fixture()
            let review = try fixture.service.review()
            switch change {
            case "hash": fixture.hooks[0]["currentHash"] = "sha256:" + String(repeating: "b", count: 64)
            case "command": fixture.hooks[0]["command"] = "different --route /hooks/codex"
            default: fixture.configVersion = "version-2"
            }
            XCTAssertThrowsError(try fixture.service.authorize(review), change)
            XCTAssertTrue(fixture.writes.isEmpty, change)
        }
    }

    func testDisabledManagedMalformedDuplicateAndForeignDefinitionsCannotBeAuthorized() throws {
        let mutations: [(inout [[String: Any]]) -> Void] = [
            { $0[0]["enabled"] = false },
            { $0[0]["isManaged"] = true },
            { $0[0]["source"] = "project" },
            { $0[0]["sourcePath"] = "/tmp/other/hooks.json" },
            { $0[0]["matcher"] = "*" },
            { $0[0]["async"] = true },
            { $0[2]["timeoutSec"] = 1 },
            { $0[0]["additionalContextLimit"] = 0 },
            { $0[2]["statusMessage"] = "Different status" },
            { $0[0]["currentHash"] = "made-up-hash" },
            { $0[0]["currentHash"] = "sha256:" + String(repeating: "g", count: 64) },
            { $0[0]["key"] = "foreign:hooks.state.trust_all" },
            { $0[0]["key"] = Fixture.hooksPath + ":bad\nkey" },
            { $0.append($0[0]) },
            { $0.removeFirst() },
        ]
        for mutation in mutations {
            let fixture = Fixture()
            mutation(&fixture.hooks)
            XCTAssertThrowsError(try fixture.service.review())
            XCTAssertTrue(fixture.writes.isEmpty)
        }
    }

    func testVendorKeysWithDotsQuotesAndBackslashesRemainOpaqueObjectKeys() throws {
        let fixture = Fixture()
        fixture.hooks[0]["key"] = Fixture.hooksPath + ":quoted.\"part\\:session_start:1:0"
        let review = try fixture.service.review()
        try fixture.service.authorize(review)
        let edits = try XCTUnwrap(fixture.writes[0]["edits"] as? [[String: Any]])
        let updates = try XCTUnwrap(edits[0]["value"] as? [String: [String: String]])
        XCTAssertNotNil(updates[review.entries[0].key])
    }

    func testUnsupportedVersionAndForeignConfigLayerNeverWrite() throws {
        let wrongVersion = Fixture()
        wrongVersion.version = "codex-cli 0.154.0"
        XCTAssertThrowsError(try wrongVersion.service.review()) { error in
            XCTAssertEqual(error as? CodexHookAuthorizationError, .unsupportedVersion)
        }
        XCTAssertEqual(wrongVersion.hookReads, 0)
        let foreignConfig = Fixture()
        foreignConfig.configFile = "/tmp/foreign/config.toml"
        XCTAssertThrowsError(try foreignConfig.service.review())
        XCTAssertTrue(foreignConfig.writes.isEmpty)
    }

    func testWriteAcknowledgementWithoutTrustedReadbackDoesNotClaimSuccess() throws {
        let fixture = Fixture()
        fixture.applyWrites = false
        let review = try fixture.service.review()
        XCTAssertThrowsError(try fixture.service.authorize(review)) { error in
            XCTAssertEqual(error as? CodexHookAuthorizationError, .verificationFailed)
        }
    }

    func testVersionConflictAndVendorErrorsDoNotProduceSuccess() throws {
        let fixture = Fixture()
        fixture.rejectWrite = true
        let review = try fixture.service.review()
        XCTAssertThrowsError(try fixture.service.authorize(review)) { error in
            XCTAssertEqual(error as? CodexHookAuthorizationError, .requestFailed)
        }
        XCTAssertFalse(try fixture.service.review().isAlreadyAuthorized)
    }

    func testAlreadyTrustedReviewDoesNotRewriteConfiguration() throws {
        let fixture = Fixture()
        for index in fixture.hooks.indices { fixture.hooks[index]["trustStatus"] = "trusted" }
        let review = try fixture.service.review()
        XCTAssertTrue(review.isAlreadyAuthorized)
        try fixture.service.authorize(review)
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    /// Synchronous in-memory vendor fixture; never launches a real process or
    /// reads/writes the user's Codex configuration.
    private final class Fixture: @unchecked Sendable {
        static let hooksPath = "/tmp/dev-island-authorization-fixture/hooks.json"
        static let configPath = "/tmp/dev-island-authorization-fixture/config.toml"
        var version = "codex-cli 0.153.4"
        var configVersion = "version-1"
        var configFile = configPath
        var hooks: [[String: Any]]
        var writes: [[String: Any]] = []
        var hookReads = 0
        var applyWrites = true
        var rejectWrite = false

        init() {
            let descriptor = LocalAgentDescriptor.codex
            let installer = LocalHooksInstaller(descriptor)
            hooks = descriptor.hookEvents.enumerated().map { index, event in
                var hook: [String: Any] = ["eventName": event.prefix(1).lowercased() + event.dropFirst(),
                 "handlerType": "command", "command": installer.hookCommand(for: event),
                 "key": Self.hooksPath + ":event:\(index):0",
                 "currentHash": "sha256:" + String(repeating: "a", count: 63) + String(index),
                 "source": "user", "sourcePath": Self.hooksPath,
                 "enabled": true, "isManaged": false, "trustStatus": "untrusted", "async": false,
                 "timeoutSec": event == "PermissionRequest" ? 100 : event == "SessionEnd" ? 1 : 600]
                if event == "PermissionRequest" { hook["statusMessage"] = "Waiting for Dev Island" }
                return hook
            }
        }

        var service: CodexHookAuthorization {
            CodexHookAuthorization(hooksPath: Self.hooksPath, configPath: Self.configPath) { [self] method, params in
                if method == "--version" { return Data(version.utf8) }
                let result: [String: Any]
                switch method {
                case "hooks/list":
                    hookReads += 1
                    let unrelated: [String: Any] = ["key": "vibe-island", "command": "vibe-island-bridge",
                                                    "sourcePath": Self.hooksPath]
                    result = ["data": [["errors": [], "hooks": hooks + [unrelated]]]]
                case "config/read":
                    result = ["layers": [["name": ["type": "user", "file": configFile],
                                           "version": configVersion, "config": [:]]]]
                case "config/batchWrite":
                    let write = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: Any])
                    writes.append(write)
                    if rejectWrite {
                        return try JSONSerialization.data(withJSONObject: ["id": 1, "error": ["code": -1]])
                    }
                    if applyWrites {
                        for index in hooks.indices { hooks[index]["trustStatus"] = "trusted" }
                    }
                    result = ["status": "ok"]
                default:
                    throw CodexHookAuthorizationError.requestFailed
                }
                return try JSONSerialization.data(withJSONObject: ["id": 1, "result": result])
            }
        }
    }
}
