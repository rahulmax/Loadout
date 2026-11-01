import XCTest
@testable import Loadout

/// Writes settings with the engine, then asks the real CLIs what they make of them,
/// with HOME and CODEX_HOME pointed at a throwaway folder. Skips if a CLI isn't installed.
final class ClaudeCLITests: XCTestCase {
    private func requireCLI() throws {
        guard runLoginShell("command -v claude").status == 0 else { throw XCTSkip("claude isn't installed") }
    }

    private func list(_ f: Fixture, in cwd: URL) -> String {
        runLoginShell("HOME=\(shellQuote(f.home.path)) claude mcp list", cwd: cwd).output
    }

    /// One closed-port HTTP server and one stdio server. Both fail fast, and both still
    /// get listed, which is all this needs.
    private func fixture() throws -> Fixture {
        let f = try Fixture()
        try f.writeJSON(f.paths.claudeJson, [
            "hasCompletedOnboarding": true,
            "mcpServers": [
                "alpha": ["type": "http", "url": "http://127.0.0.1:9/mcp"],
                "tool": ["command": "/usr/bin/false"],
            ],
        ])
        return f
    }

    func testAllowlistTurnsOnOnlyInTheChosenProject() throws {
        try requireCLI()
        let f = try fixture()
        let other = f.root.appendingPathComponent("work/other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let project = URL(fileURLWithPath: f.project)

        var output = list(f, in: project)
        XCTAssertTrue(output.contains("alpha:"), "Baseline should list alpha:\n\(output)")
        XCTAssertTrue(output.contains("tool:"), "Baseline should list tool:\n\(output)")

        try Migration.apply(paths: f.paths, state: &f.engine.state, writer: f.writer)
        output = list(f, in: project)
        XCTAssertTrue(output.contains("alpha:") && output.contains("tool:"), "The switch must change nothing:\n\(output)")

        try f.engine.setService(try f.service("Alpha", .allProjects), on: false, scope: .allProjects)
        try f.engine.setService(try f.service("Tool", .allProjects), on: false, scope: .allProjects)
        output = list(f, in: project)
        XCTAssertFalse(output.contains("alpha:"), "Default off:\n\(output)")
        XCTAssertFalse(output.contains("tool:"), "Default off:\n\(output)")

        let scope = Scope.project(f.project)
        try f.engine.setService(try f.service("Alpha", scope), on: true, scope: scope)
        try f.engine.setService(try f.service("Tool", scope), on: true, scope: scope)
        output = list(f, in: project)
        XCTAssertTrue(output.contains("alpha:"), "On in this project:\n\(output)")
        XCTAssertTrue(output.contains("tool:"), "On in this project:\n\(output)")
        output = list(f, in: other)
        XCTAssertFalse(output.contains("alpha:"), "Still off elsewhere:\n\(output)")
        XCTAssertFalse(output.contains("tool:"), "Still off elsewhere:\n\(output)")

        try f.engine.resetService(try f.service("Alpha", scope), scope: scope)
        output = list(f, in: project)
        XCTAssertFalse(output.contains("alpha:"), "Reset:\n\(output)")
        XCTAssertTrue(output.contains("tool:"), "Reset of one leaves the other:\n\(output)")
    }

    func testProjectOffBeatsDefaultOn() throws {
        try requireCLI()
        let f = try fixture()
        try Migration.apply(paths: f.paths, state: &f.engine.state, writer: f.writer)
        let scope = Scope.project(f.project)
        try f.engine.setService(try f.service("Alpha", scope), on: false, scope: scope)
        let output = list(f, in: URL(fileURLWithPath: f.project))
        XCTAssertFalse(output.contains("alpha:"), output)
        XCTAssertTrue(output.contains("tool:"), output)
    }

    func testProjectServerSurvivesTheSwitch() throws {
        try requireCLI()
        let f = try fixture()
        var json = try f.settings(f.paths.claudeJson)
        json["projects"] = [f.project: ["mcpServers": ["only-here": ["command": "/usr/bin/false"]], "hasTrustDialogAccepted": true]]
        try f.writeJSON(f.paths.claudeJson, json)
        try Migration.apply(paths: f.paths, state: &f.engine.state, writer: f.writer)
        let output = list(f, in: URL(fileURLWithPath: f.project))
        XCTAssertTrue(output.contains("only-here:"), output)
    }
}

final class CodexCLITests: XCTestCase {
    private func requireCLI() throws {
        guard runLoginShell("command -v codex").status == 0 else { throw XCTSkip("codex isn't installed") }
    }

    /// `codex mcp list --json` reports each server's merged `enabled` for the folder.
    private func enabled(_ f: Fixture, name: String) throws -> Bool? {
        let command = "CODEX_HOME=\(shellQuote(f.paths.codexDir.path)) command codex mcp list --json"
        let output = runLoginShell(command, cwd: URL(fileURLWithPath: f.project)).output
        let data = try XCTUnwrap(output.data(using: .utf8))
        let servers = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]], output)
        return servers.first { $0["name"] as? String == name }?["enabled"] as? Bool
    }

    func testTrustedProjectOverrideBothWays() throws {
        try requireCLI()
        let f = try Fixture()
        f.engine.state.harnesses["codex"] = true
        try f.write(f.paths.codexConfig, """
        [mcp_servers.alpha]
        command = "/usr/bin/false"

        [mcp_servers.beta]
        command = "/usr/bin/false"
        enabled = false

        """)
        try f.engine.trustCodex(project: f.project)
        XCTAssertEqual(try enabled(f, name: "alpha"), true)
        XCTAssertEqual(try enabled(f, name: "beta"), false)

        let scope = Scope.project(f.project)
        try f.engine.setService(try f.service("Alpha", scope), on: false, scope: scope)
        try f.engine.setService(try f.service("Beta", scope), on: true, scope: scope)
        XCTAssertEqual(try enabled(f, name: "alpha"), false)
        XCTAssertEqual(try enabled(f, name: "beta"), true)

        try f.engine.resetService(try f.service("Alpha", scope), scope: scope)
        try f.engine.resetService(try f.service("Beta", scope), scope: scope)
        XCTAssertEqual(try enabled(f, name: "alpha"), true)
        XCTAssertEqual(try enabled(f, name: "beta"), false)
    }

    func testAddedServerAppearsOnlyInThatProject() throws {
        try requireCLI()
        let f = try Fixture()
        f.engine.state.harnesses["codex"] = true
        try f.writeJSON(f.paths.claudeJson, ["mcpServers": ["gamma": ["command": "/usr/bin/false", "args": ["--x y"]]]])
        try f.write(f.paths.codexConfig, "")
        try f.engine.trustCodex(project: f.project)

        let scope = Scope.project(f.project)
        XCTAssertNil(try enabled(f, name: "gamma"))
        let add = try XCTUnwrap(try f.service("Gamma", scope).controls.first { $0.harness == .codex })
        try f.engine.set(add, on: true, scope: scope)
        XCTAssertEqual(try enabled(f, name: "gamma"), true)
    }
}
