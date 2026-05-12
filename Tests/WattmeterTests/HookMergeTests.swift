import XCTest
@testable import Wattmeter

final class HookMergeTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wattmeter-hook-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpDir { try? FileManager.default.removeItem(at: d) }
    }

    private func write(_ json: [String: Any]) throws -> URL {
        let url = tmpDir.appendingPathComponent("settings.json")
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private let wrapperPath = "/Users/test/.claude/wattmeter/log_tool.sh"

    // MARK: install

    func testInstallAddsHooksWhenNonePresent() throws {
        let url = try write(["statusLine": ["command": "echo hi"]])
        let res = LimitsConfig.mergeToolHooks(settingsURL: url, wrapperPath: wrapperPath)
        XCTAssertEqual(res, .installed)
        let obj = try read(url)
        let hooks = obj["hooks"] as! [String: Any]
        let pre = hooks["PreToolUse"] as! [Any]
        let post = hooks["PostToolUse"] as! [Any]
        XCTAssertEqual(pre.count, 1)
        XCTAssertEqual(post.count, 1)
        // unrelated keys preserved
        let sl = obj["statusLine"] as! [String: Any]
        XCTAssertEqual(sl["command"] as? String, "echo hi")
    }

    func testInstallIsIdempotent() throws {
        let url = try write([:])
        XCTAssertEqual(LimitsConfig.mergeToolHooks(settingsURL: url, wrapperPath: wrapperPath), .installed)
        XCTAssertEqual(LimitsConfig.mergeToolHooks(settingsURL: url, wrapperPath: wrapperPath), .alreadyInstalled)
        // Verify the hook arrays still have exactly 1 entry each.
        let obj = try read(url)
        let hooks = obj["hooks"] as! [String: Any]
        XCTAssertEqual((hooks["PreToolUse"] as! [Any]).count, 1)
        XCTAssertEqual((hooks["PostToolUse"] as! [Any]).count, 1)
    }

    /// CRITICAL: user has a pre-existing PreToolUse hook. install + uninstall MUST preserve it.
    func testPreservesExistingUserHooksRoundTrip() throws {
        // Simulate a real-looking user PreToolUse entry pointing at their own script.
        let userEntry: [String: Any] = [
            "matcher": "Bash",
            "hooks": [
                [
                    "type": "command",
                    "command": "/Users/test/.claude/security/audit_bash.sh"
                ] as [String: Any]
            ]
        ]
        // Pre-existing PostToolUse entry too.
        let userPost: [String: Any] = [
            "matcher": "*",
            "hooks": [
                ["type": "command", "command": "/usr/local/bin/sentry_log post"] as [String: Any]
            ]
        ]
        let initial: [String: Any] = [
            "permissions": ["allow": ["*"]],
            "statusLine": ["type": "command", "command": "/some/statusline.sh"],
            "hooks": [
                "PreToolUse": [userEntry],
                "PostToolUse": [userPost]
            ]
        ]
        let url = try write(initial)

        // Install.
        XCTAssertEqual(LimitsConfig.mergeToolHooks(settingsURL: url, wrapperPath: wrapperPath), .installed)
        let afterInstall = try read(url)
        let hooks = afterInstall["hooks"] as! [String: Any]
        let pre = hooks["PreToolUse"] as! [Any]
        let post = hooks["PostToolUse"] as! [Any]
        XCTAssertEqual(pre.count, 2, "expected user entry + ours")
        XCTAssertEqual(post.count, 2)
        // User's command still present.
        XCTAssertTrue(pre.contains { item in
            guard let d = item as? [String: Any],
                  let inner = d["hooks"] as? [Any],
                  let first = inner.first as? [String: Any] else { return false }
            return (first["command"] as? String) == "/Users/test/.claude/security/audit_bash.sh"
        })
        // Ours present with marker prefix.
        XCTAssertTrue(pre.contains { item in
            guard let d = item as? [String: Any],
                  let inner = d["hooks"] as? [Any],
                  let first = inner.first as? [String: Any],
                  let cmd = first["command"] as? String else { return false }
            return cmd.hasPrefix(wrapperPath)
        })
        // Idempotent re-install.
        XCTAssertEqual(LimitsConfig.mergeToolHooks(settingsURL: url, wrapperPath: wrapperPath), .alreadyInstalled)

        // Uninstall.
        XCTAssertEqual(LimitsConfig.filterToolHooks(settingsURL: url, markerPrefix: wrapperPath), .removed)
        let afterRemove = try read(url)
        let hooks2 = afterRemove["hooks"] as! [String: Any]
        let pre2 = hooks2["PreToolUse"] as! [Any]
        let post2 = hooks2["PostToolUse"] as! [Any]
        XCTAssertEqual(pre2.count, 1, "user PreToolUse entry must survive uninstall")
        XCTAssertEqual(post2.count, 1, "user PostToolUse entry must survive uninstall")
        let preUser = pre2.first as! [String: Any]
        let preInner = (preUser["hooks"] as! [Any]).first as! [String: Any]
        XCTAssertEqual(preInner["command"] as? String, "/Users/test/.claude/security/audit_bash.sh")
        // Top-level user keys preserved across the round-trip.
        XCTAssertNotNil(afterRemove["permissions"])
        XCTAssertNotNil(afterRemove["statusLine"])
    }

    func testRemoveOnMissingFileReportsMissing() {
        let url = tmpDir.appendingPathComponent("nope.json")
        XCTAssertEqual(LimitsConfig.filterToolHooks(settingsURL: url, markerPrefix: wrapperPath), .settingsMissing)
    }

    func testRemoveWhenNoneInstalledReportsNotInstalled() throws {
        let url = try write(["hooks": ["PreToolUse": [[
            "matcher": "*",
            "hooks": [["type": "command", "command": "/foo/bar.sh"] as [String: Any]]
        ] as [String: Any]]]])
        XCTAssertEqual(LimitsConfig.filterToolHooks(settingsURL: url, markerPrefix: wrapperPath), .notInstalled)
    }

    /// If the only hook entries were ours, after removal the `hooks` key should be dropped
    /// (don't leave stranded empty containers in the user's settings).
    func testRemovalDropsEmptyContainers() throws {
        let url = try write([:])
        XCTAssertEqual(LimitsConfig.mergeToolHooks(settingsURL: url, wrapperPath: wrapperPath), .installed)
        XCTAssertEqual(LimitsConfig.filterToolHooks(settingsURL: url, markerPrefix: wrapperPath), .removed)
        let obj = try read(url)
        XCTAssertNil(obj["hooks"], "empty hooks dict should be removed after uninstall")
    }

    /// installToolHooks: full install incl. wrapper script copy.
    @MainActor
    func testInstallToolHooksCopiesScriptAndMerges() throws {
        // Provide a fake "bundled" script.
        let source = tmpDir.appendingPathComponent("source/log_tool.sh")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: source, atomically: true, encoding: .utf8)

        let dest = tmpDir.appendingPathComponent("wrapper/log_tool.sh")
        // Reach into copyHookWrapper directly (instance helper would target ~/.claude).
        XCTAssertTrue(LimitsConfig.copyHookWrapper(from: source, to: dest))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.path))

        let url = try write([:])
        XCTAssertEqual(LimitsConfig.mergeToolHooks(settingsURL: url, wrapperPath: dest.path), .installed)
        // The marker prefix uses the wrapper destination path.
        XCTAssertEqual(LimitsConfig.filterToolHooks(settingsURL: url, markerPrefix: dest.path), .removed)
    }
}
