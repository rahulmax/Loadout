import XCTest
@testable import Loadout

/// A throwaway home and project on disk. Nothing here touches the real home.
final class Fixture {
    let root: URL
    let home: URL
    let project: String
    let paths: Paths
    var state = AppState()
    let writer = ConfigWriter()
    lazy var engine = Engine(paths: paths, state: state, writer: writer)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loadout-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("home")
        let projectUrl = root.appendingPathComponent("work/app")
        project = projectUrl.path
        paths = Paths(home: home)
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
        try fm.createDirectory(at: projectUrl, withIntermediateDirectories: true)
        try write(paths.claudeSettings, "{}")
        try write(paths.claudeJson, "{}")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func writeJSON(_ url: URL, _ json: [String: Any]) throws {
        try write(url, String(data: try encodeJSONObject(json), encoding: .utf8)!)
    }

    func addSkill(_ name: String, description: String = "Does a thing", extra: String = "", under dir: URL? = nil) throws {
        let folder = (dir ?? paths.userSkills).appendingPathComponent(name)
        try write(folder.appendingPathComponent("SKILL.md"), "---\nname: \(name)\ndescription: \(description)\n\(extra)---\nBody\n")
    }

    func addPlugin(_ id: String, server: [String: Any]? = nil, skills: [String] = []) throws {
        let name = String(id.split(separator: "@").first!)
        let dir = root.appendingPathComponent("plugins/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let server { try writeJSON(dir.appendingPathComponent(".mcp.json"), [name: server]) }
        for skill in skills {
            try addSkill(skill, under: dir.appendingPathComponent("skills"))
        }
        var installed = (try? readJSONObject(paths.installedPlugins)) ?? [:]
        var map = installed["plugins"] as? [String: Any] ?? [:]
        map[id] = [["installPath": dir.path, "version": "1"]]
        installed["plugins"] = map
        try writeJSON(paths.installedPlugins, installed)
    }

    func inventory(_ scope: Scope) throws -> Inventory {
        try InventoryLoader(paths: paths, state: engine.state).load(scope: scope)
    }

    func service(_ name: String, _ scope: Scope) throws -> Service {
        try XCTUnwrap(try inventory(scope).services.first { $0.name == name }, "No service \(name)")
    }

    func settings(_ url: URL) throws -> [String: Any] { try readJSONObject(url) }
}

final class RuleTests: XCTestCase {
    func testGlob() {
        XCTAssertTrue(ClaudeRules.glob("https://mcp.figma.com/*", matches: "https://mcp.figma.com/mcp"))
        XCTAssertTrue(ClaudeRules.glob("https://*higgsfield.ai*", matches: "https://mcp.higgsfield.ai/mcp"))
        XCTAssertFalse(ClaudeRules.glob("https://mcp.figma.com/*", matches: "https://mcp.figma.com.evil.example/mcp"))
        XCTAssertFalse(ClaudeRules.glob("exact", matches: "exactly"))
    }

    func testUrlPatternKeepsAnthropicExact() {
        XCTAssertEqual(ClaudeRule.urlPattern("https://mcp.slack.com/mcp"), "https://mcp.slack.com/*")
        XCTAssertEqual(ClaudeRule.urlPattern("http://127.0.0.1:3845/mcp"), "http://127.0.0.1:3845/*")
        XCTAssertEqual(ClaudeRule.urlPattern("https://api.anthropic.com/v1/pages/mcp"), "https://api.anthropic.com/v1/pages/mcp")
    }

    func testNameAllowDoesNotMatchConnector() {
        let ref = ClaudeServerRef(
            names: ["claude.ai Slack"], urls: ["https://mcp.slack.com/mcp"], command: nil,
            allowableNames: [], allowRule: .url("https://mcp.slack.com/*"), denyRule: .url("https://mcp.slack.com/*")
        )
        XCTAssertFalse(ClaudeRules.entry(["serverName": "claude.ai Slack"], matches: ref, forAllow: true))
        XCTAssertTrue(ClaudeRules.entry(["serverName": "claude.ai Slack"], matches: ref, forAllow: false))
        XCTAssertTrue(ClaudeRules.entry(["serverUrl": "https://mcp.slack.com/*"], matches: ref, forAllow: true))
    }

    func testParseMcpList() {
        let parsed = parseMcpList("""
        Checking MCP server health…

        claude.ai Higgsfield: https://mcp.higgsfield.ai/mcp - ! Needs authentication
        figma: https://mcp.figma.com/mcp (HTTP) - ✔ Connected
        plugin:x:y: npx some-pkg@latest - ✘ Failed to connect
        """)
        XCTAssertEqual(parsed.map(\.name), ["claude.ai Higgsfield", "figma", "plugin:x:y"])
        XCTAssertEqual(parsed[0].status, "Needs authentication")
        XCTAssertEqual(parsed[1].url, "https://mcp.figma.com/mcp")
        XCTAssertEqual(parsed[1].status, "Connected")
    }
}

final class TOMLTests: XCTestCase {
    let sample = """
    # top comment
    model = "x"

    [mcp_servers.pencil] # inline
    command = "/bin/pencil"
    args = ["--a", "b"]

    [plugins."github@openai-curated"]
    enabled = true # keep me

    [[skills.config]]
    path = "/x"
    enabled = false

    [projects."/Users/me/a b"]
    trust_level = "trusted"
    """

    func testReads() {
        let doc = TOMLDocument(sample)
        XCTAssertEqual(doc.children(of: "mcp_servers"), ["pencil"])
        XCTAssertEqual(doc.string(["mcp_servers", "pencil"], "command"), "/bin/pencil")
        XCTAssertEqual(doc.stringArray(["mcp_servers", "pencil"], "args"), ["--a", "b"])
        XCTAssertEqual(doc.bool(["plugins", "github@openai-curated"], "enabled"), true)
        XCTAssertEqual(doc.string(["projects", "/Users/me/a b"], "trust_level"), "trusted")
    }

    func testArrayTableIsNotASection() {
        XCTAssertNil(TOMLDocument(sample).section(["skills", "config"]))
    }

    func testEditKeepsCommentsAndOtherLines() {
        var doc = TOMLDocument(sample)
        doc.set(["plugins", "github@openai-curated"], "enabled", rawValue: "false")
        doc.set(["mcp_servers", "pencil"], "enabled", rawValue: "false")
        XCTAssertTrue(doc.text.contains("# top comment"))
        XCTAssertTrue(doc.text.contains("[mcp_servers.pencil] # inline"))
        XCTAssertEqual(doc.bool(["plugins", "github@openai-curated"], "enabled"), false)
        XCTAssertEqual(doc.bool(["mcp_servers", "pencil"], "enabled"), false)
        XCTAssertEqual(doc.string(["mcp_servers", "pencil"], "command"), "/bin/pencil")
        // The [[skills.config]] table isn't touched by nearby edits.
        XCTAssertTrue(doc.text.contains("[[skills.config]]\npath = \"/x\"\nenabled = false"))
    }

    func testNewSectionQuotesOddNames() {
        var doc = TOMLDocument("")
        doc.set(["plugins", "a@b"], "enabled", rawValue: "false")
        XCTAssertEqual(doc.text, "[plugins.\"a@b\"]\nenabled = false\n")
        XCTAssertEqual(doc.bool(["plugins", "a@b"], "enabled"), false)
    }

    func testRemoveKeyAndSection() {
        var doc = TOMLDocument("[a]\nx = 1\n\n[b]\ny = 2\n")
        doc.remove(["a"], "x")
        XCTAssertTrue(doc.isEmpty(["a"]))
        doc.removeSection(["a"])
        XCTAssertEqual(doc.text, "[b]\ny = 2\n")
        doc.removeSection(["b"])
        XCTAssertTrue(doc.isBlank)
    }

    func testMultiLineArrayDoesNotConfuseSections() {
        let doc = TOMLDocument("[a]\nargs = [\n  \"[not a header]\",\n  \"x = 1\",\n]\nenabled = true\n[b]\ny = 2\n")
        XCTAssertEqual(doc.bool(["a"], "enabled"), true)
        XCTAssertNotNil(doc.section(["b"]))
        XCTAssertEqual(doc.sections.count, 2)
    }
}

final class WriterTests: XCTestCase {
    func testEditJSONAndUndoRestoresExactBytes() throws {
        let f = try Fixture()
        let original = "{ \"a\":1 }\n"
        try f.write(f.paths.claudeSettings, original)
        try f.writer.editJSON(f.paths.claudeSettings) { $0["b"] = 2 }
        let change = f.writer.finishChange()
        XCTAssertEqual(try f.settings(f.paths.claudeSettings)["b"] as? Int, 2)
        try f.writer.undo(change)
        XCTAssertEqual(try String(contentsOf: f.paths.claudeSettings, encoding: .utf8), original)
    }

    func testRemoveIfEmptyDeletesFileAndFolder() throws {
        let f = try Fixture()
        let url = f.paths.claudeLocal(f.project)
        try f.writer.editJSON(url, removeIfEmpty: true) { $0["a"] = 1 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try f.writer.editJSON(url, removeIfEmpty: true) { $0.removeValue(forKey: "a") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    func testUndoRefusesIfFileChangedElsewhere() throws {
        let f = try Fixture()
        try f.writer.editJSON(f.paths.claudeSettings) { $0["a"] = 1 }
        let change = f.writer.finishChange()
        try f.write(f.paths.claudeSettings, "{\"someone\":\"else\"}")
        XCTAssertThrowsError(try f.writer.undo(change))
        XCTAssertEqual(try f.settings(f.paths.claudeSettings)["someone"] as? String, "else")
    }

    func testReadOnlyNeverWrites() throws {
        let f = try Fixture()
        let writer = ConfigWriter(readOnly: true)
        XCTAssertThrowsError(try writer.editJSON(f.paths.claudeSettings) { $0["a"] = 1 })
        XCTAssertNil(try f.settings(f.paths.claudeSettings)["a"])
    }

    func testKeepsPermissions() throws {
        let f = try Fixture()
        let url = f.home.appendingPathComponent("private.toml")
        try f.write(url, "a = 1\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try f.writer.writeText("a = 2\n", to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testMalformedJSONIsNotOverwritten() throws {
        let f = try Fixture()
        try f.write(f.paths.claudeSettings, "{ broken")
        XCTAssertThrowsError(try f.writer.editJSON(f.paths.claudeSettings) { $0["a"] = 1 })
        XCTAssertEqual(try String(contentsOf: f.paths.claudeSettings, encoding: .utf8), "{ broken")
    }
}

final class GroupingTests: XCTestCase {
    func testFigmaInThreePlacesIsOneService() throws {
        let f = try Fixture()
        try f.writeJSON(f.paths.claudeJson, [
            "mcpServers": ["figma": ["type": "http", "url": "https://mcp.figma.com/mcp"]],
            "claudeAiMcpEverConnected": ["claude.ai Figma"],
        ])
        try f.addPlugin("figma@official", server: ["type": "http", "url": "https://mcp.figma.com/mcp"], skills: ["figma-use", "figma-spec"])
        let inventory = try f.inventory(.allProjects)
        let figma = inventory.services.filter { $0.name == "Figma" }
        XCTAssertEqual(figma.count, 1)
        XCTAssertEqual(inventory.services.count, 1)
        XCTAssertEqual(figma[0].pluginSkills.count, 2)
        // One plugin switch plus one server switch: the URL rule covers all three copies.
        XCTAssertEqual(figma[0].controls.count, 2)
        XCTAssertEqual(figma[0].kindSummary, "Plugin + MCP")
    }

    func testEveryConnectorListedWithoutACatalog() throws {
        let f = try Fixture()
        try f.writeJSON(f.paths.claudeJson, ["claudeAiMcpEverConnected": ["claude.ai Higgsfield", "claude.ai Atlassian"]])
        f.engine.state.connectors["claude.ai Brand New"] = "https://mcp.brandnew.example/mcp"
        let names = try f.inventory(.allProjects).services.map(\.name)
        XCTAssertEqual(names, ["Atlassian", "Brand New", "Higgsfield"])
    }

    func testConnectorOnlyInADenyEntryStaysListed() throws {
        let f = try Fixture()
        try f.writeJSON(f.paths.claudeSettings, ["deniedMcpServers": [["serverName": "claude.ai Higgsfield"]]])
        let service = try f.service("Higgsfield", .allProjects)
        XCTAssertFalse(service.isOn)
    }
}

final class ClaudeScopeTests: XCTestCase {
    private func migrated() throws -> Fixture {
        let f = try Fixture()
        try f.writeJSON(f.paths.claudeJson, [
            "mcpServers": [
                "alpha": ["type": "http", "url": "https://alpha.example/mcp"],
                "tool": ["command": "/bin/tool", "args": ["--x"]],
            ],
        ])
        try f.writeJSON(f.paths.claudeSettings, ["allowedMcpServers": []])
        return f
    }

    func testDefaultOffThenOnInOneProject() throws {
        let f = try migrated()
        let scope = Scope.project(f.project)
        var alpha = try f.service("Alpha", scope)
        XCTAssertFalse(alpha.isOn)
        XCTAssertFalse(alpha.setHere)

        try f.engine.setService(alpha, on: true, scope: scope)
        let local = try f.settings(f.paths.claudeLocal(f.project))
        XCTAssertEqual((local["allowedMcpServers"] as? [[String: String]])?.first?["serverUrl"], "https://alpha.example/*")

        alpha = try f.service("Alpha", scope)
        XCTAssertTrue(alpha.isOn)
        XCTAssertTrue(alpha.setHere)
        // The default and other projects are untouched.
        XCTAssertFalse(try f.service("Alpha", .allProjects).isOn)
    }

    func testProjectOffWinsOverDefaultOn() throws {
        let f = try migrated()
        try f.engine.setService(try f.service("Alpha", .allProjects), on: true, scope: .allProjects)
        XCTAssertTrue(try f.service("Alpha", .allProjects).isOn)
        let scope = Scope.project(f.project)
        XCTAssertTrue(try f.service("Alpha", scope).isOn)
        try f.engine.setService(try f.service("Alpha", scope), on: false, scope: scope)
        XCTAssertFalse(try f.service("Alpha", scope).isOn)
        XCTAssertTrue(try f.service("Alpha", .allProjects).isOn)
    }

    func testResetReturnsToDefaultAndRemovesFile() throws {
        let f = try migrated()
        let scope = Scope.project(f.project)
        try f.engine.setService(try f.service("Alpha", scope), on: true, scope: scope)
        try f.engine.resetService(try f.service("Alpha", scope), scope: scope)
        XCTAssertFalse(try f.service("Alpha", scope).isOn)
        XCTAssertFalse(try f.service("Alpha", scope).setHere)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.claudeLocal(f.project).path))
    }

    func testDefaultOffDoesNotUseTheDenyList() throws {
        let f = try migrated()
        try f.engine.setService(try f.service("Alpha", .allProjects), on: true, scope: .allProjects)
        try f.engine.setService(try f.service("Alpha", .allProjects), on: false, scope: .allProjects)
        let user = try f.settings(f.paths.claudeSettings)
        XCTAssertNil(user["deniedMcpServers"], "A global deny can't be undone by a project")
        XCTAssertEqual((user["allowedMcpServers"] as? [Any])?.count, 0, "The empty allowlist must stay: it means default-off")
    }

    func testStdioServerUsesName() throws {
        let f = try migrated()
        let scope = Scope.project(f.project)
        try f.engine.setService(try f.service("Tool", scope), on: true, scope: scope)
        let local = try f.settings(f.paths.claudeLocal(f.project))
        XCTAssertEqual((local["allowedMcpServers"] as? [[String: String]])?.first?["serverName"], "tool")
    }

    func testPluginServerStdioUsesCommand() throws {
        let f = try migrated()
        try f.addPlugin("pw@official", server: ["command": "npx", "args": ["@playwright/mcp@latest"]])
        let scope = Scope.project(f.project)
        try f.engine.setService(try f.service("Pw", scope), on: true, scope: scope)
        let local = try f.settings(f.paths.claudeLocal(f.project))
        let allow = try XCTUnwrap(local["allowedMcpServers"] as? [[String: Any]])
        XCTAssertEqual(allow.first?["serverCommand"] as? [String], ["npx", "@playwright/mcp@latest"])
        XCTAssertEqual((local["enabledPlugins"] as? [String: Bool])?["pw@official"], true)
    }

    func testConnectorAllowedByUrlNotName() throws {
        let f = try migrated()
        f.engine.state.connectors["claude.ai Slack"] = "https://mcp.slack.com/mcp"
        let scope = Scope.project(f.project)
        try f.engine.setService(try f.service("Slack", scope), on: true, scope: scope)
        let local = try f.settings(f.paths.claudeLocal(f.project))
        XCTAssertEqual((local["allowedMcpServers"] as? [[String: String]])?.first?["serverUrl"], "https://mcp.slack.com/*")
    }

    func testConnectorWithNoUrlIsLockedWhenOff() throws {
        let f = try migrated()
        var json = try f.settings(f.paths.claudeJson)
        json["claudeAiMcpEverConnected"] = ["claude.ai Atlassian"]
        try f.writeJSON(f.paths.claudeJson, json)
        let service = try f.service("Atlassian", .project(f.project))
        XCTAssertEqual(service.switchable.count, 0)
        XCTAssertNotNil(service.firstLockReason)
    }

    func testGlobalDenyLocksProjectUntilMigrated() throws {
        let f = try Fixture()
        try f.writeJSON(f.paths.claudeJson, ["mcpServers": ["alpha": ["url": "https://alpha.example/mcp"]]])
        try f.writeJSON(f.paths.claudeSettings, ["deniedMcpServers": [["serverName": "alpha"]]])
        let service = try f.service("Alpha", .project(f.project))
        XCTAssertEqual(service.active.first?.lock?.fix, .switchToPerProject)
        XCTAssertEqual(service.mainState, .locked(on: false))
    }

    func testBeforeMigrationAllProjectsStillUsesDeny() throws {
        let f = try Fixture()
        try f.writeJSON(f.paths.claudeJson, ["mcpServers": ["alpha": ["url": "https://alpha.example/mcp"]]])
        try f.engine.setService(try f.service("Alpha", .allProjects), on: false, scope: .allProjects)
        XCTAssertNotNil(try f.settings(f.paths.claudeSettings)["deniedMcpServers"])
        XCTAssertNil(try f.settings(f.paths.claudeSettings)["allowedMcpServers"])
        XCTAssertFalse(try f.service("Alpha", .allProjects).isOn)
    }

    func testRepoDenyLocksRow() throws {
        let f = try migrated()
        try f.writeJSON(f.paths.claudeShared(f.project), ["deniedMcpServers": [["serverName": "alpha"]]])
        let service = try f.service("Alpha", .project(f.project))
        XCTAssertEqual(service.mainState, .locked(on: false))
        XCTAssertTrue(service.firstLockReason?.contains(".claude/settings.json") == true)
    }

    func testSlashDisableIsSeenAndClearedOnOn() throws {
        let f = try migrated()
        try f.engine.setService(try f.service("Alpha", .allProjects), on: true, scope: .allProjects)
        var json = try f.settings(f.paths.claudeJson)
        json["projects"] = [f.project: ["disabledMcpServers": ["alpha", "other"], "keep": 1]]
        try f.writeJSON(f.paths.claudeJson, json)

        let scope = Scope.project(f.project)
        XCTAssertFalse(try f.service("Alpha", scope).isOn)
        try f.engine.setService(try f.service("Alpha", scope), on: true, scope: scope)
        XCTAssertTrue(try f.service("Alpha", scope).isOn)

        let change = f.writer.finishChange()
        func entry() throws -> [String: Any] {
            let projects = try f.settings(f.paths.claudeJson)["projects"] as? [String: [String: Any]]
            return try XCTUnwrap(projects?[f.project])
        }
        XCTAssertEqual(try entry()["disabledMcpServers"] as? [String], ["other"])
        XCTAssertEqual(try entry()["keep"] as? Int, 1)

        // Undo re-adds the name even though the file changed in between.
        var later = try f.settings(f.paths.claudeJson)
        later["written-by-a-session"] = true
        try f.writeJSON(f.paths.claudeJson, later)
        try f.writer.undo(change)
        XCTAssertEqual(try Set(entry()["disabledMcpServers"] as? [String] ?? []), ["alpha", "other"])
        XCTAssertEqual(try f.settings(f.paths.claudeJson)["written-by-a-session"] as? Bool, true)
    }

    func testPluginPerProjectBothWays() throws {
        let f = try Fixture()
        try f.addPlugin("vercel@official", skills: ["deploy"])
        try f.writeJSON(f.paths.claudeSettings, ["enabledPlugins": ["vercel@official": false]])
        let scope = Scope.project(f.project)
        XCTAssertFalse(try f.service("Vercel", scope).isOn)
        try f.engine.setService(try f.service("Vercel", scope), on: true, scope: scope)
        XCTAssertTrue(try f.service("Vercel", scope).isOn)
        XCTAssertFalse(try f.service("Vercel", .allProjects).isOn)
        XCTAssertEqual(try f.service("Vercel", scope).tokens, try f.service("Vercel", .allProjects).tokens)
    }
}

final class MigrationTests: XCTestCase {
    private func legacy() throws -> Fixture {
        let f = try Fixture()
        try f.writeJSON(f.paths.claudeJson, [
            "mcpServers": [
                "figma": ["url": "https://mcp.figma.com/mcp"],
                "pencil": ["command": "/bin/pencil"],
            ],
            "claudeAiMcpEverConnected": ["claude.ai Higgsfield", "claude.ai Claude Docs", "claude.ai Gmail"],
            "projects": [f.project: ["mcpServers": ["only-here": ["command": "/bin/x"]]]],
        ])
        f.engine.state.connectors = [
            "claude.ai Higgsfield": "https://mcp.higgsfield.ai/mcp",
            "claude.ai Claude Docs": "https://api.anthropic.com/v1/pages/mcp",
            "claude.ai Gmail": "https://gmailmcp.googleapis.com/mcp/v1",
        ]
        try f.writeJSON(f.paths.claudeSettings, [
            "theme": "dark",
            "deniedMcpServers": [
                ["serverName": "pencil"],
                ["serverName": "claude.ai Higgsfield"],
                ["serverUrl": "https://*higgsfield.ai*"],
                ["serverUrl": "https://gmailmcp.googleapis.com/mcp/v1"],
                ["serverCommand": ["/bin/custom-block"]],
            ],
        ])
        return f
    }

    func testSameOnOffAfterTheSwitch() throws {
        let f = try legacy()
        func states() throws -> [String: Bool] {
            let services = try f.inventory(.allProjects).services
            return Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0.isOn) })
        }
        let before = try states()
        try Migration.apply(paths: f.paths, state: &f.engine.state, writer: f.writer)
        XCTAssertEqual(try states(), before)
        XCTAssertEqual(before["Figma"], true)
        XCTAssertEqual(before["Higgsfield"], false)
        XCTAssertEqual(before["Claude Docs"], true)
    }

    func testListsAfterTheSwitch() throws {
        let f = try legacy()
        let summary = try Migration.apply(paths: f.paths, state: &f.engine.state, writer: f.writer)
        let user = try f.settings(f.paths.claudeSettings)
        let allow = try XCTUnwrap(user["allowedMcpServers"] as? [[String: Any]])
        XCTAssertTrue(allow.contains { $0["serverUrl"] as? String == "https://mcp.figma.com/*" })
        XCTAssertTrue(allow.contains { $0["serverUrl"] as? String == "https://api.anthropic.com/v1/pages/mcp" })
        XCTAssertTrue(allow.contains { $0["serverName"] as? String == "only-here" }, "Project-only servers must keep working")
        XCTAssertFalse(allow.contains { ($0["serverUrl"] as? String)?.contains("higgsfield") == true })
        XCTAssertFalse(allow.contains { $0["serverName"] as? String == "pencil" })
        // Only the block nothing known matches survives.
        let deny = try XCTUnwrap(user["deniedMcpServers"] as? [[String: Any]])
        XCTAssertEqual(deny.count, 1)
        XCTAssertEqual(deny.first?["serverCommand"] as? [String], ["/bin/custom-block"])
        XCTAssertEqual(summary.removedBlocks, 4)
        XCTAssertEqual(summary.keptBlocks, 1)
        XCTAssertEqual(user["theme"] as? String, "dark")
    }

    func testProjectCanTurnOnWhatWasBlockedAfterTheSwitch() throws {
        let f = try legacy()
        let scope = Scope.project(f.project)
        XCTAssertEqual(try f.service("Higgsfield", scope).mainState, .locked(on: false))
        try Migration.apply(paths: f.paths, state: &f.engine.state, writer: f.writer)
        let service = try f.service("Higgsfield", scope)
        XCTAssertEqual(service.mainState, .off)
        try f.engine.setService(service, on: true, scope: scope)
        XCTAssertTrue(try f.service("Higgsfield", scope).isOn)
        XCTAssertFalse(try f.service("Higgsfield", .allProjects).isOn)
    }

    func testRestorePutsListsBackAndKeepsLaterSettings() throws {
        let f = try legacy()
        let original = try f.settings(f.paths.claudeSettings)["deniedMcpServers"] as? [[String: Any]]
        try Migration.apply(paths: f.paths, state: &f.engine.state, writer: f.writer)
        var user = try f.settings(f.paths.claudeSettings)
        user["newer"] = 1
        try f.writeJSON(f.paths.claudeSettings, user)

        try Migration.restore(paths: f.paths, state: &f.engine.state, writer: f.writer)
        let restored = try f.settings(f.paths.claudeSettings)
        XCTAssertNil(restored["allowedMcpServers"])
        XCTAssertEqual((restored["deniedMcpServers"] as? [[String: Any]])?.count, original?.count)
        XCTAssertEqual(restored["newer"] as? Int, 1)
        XCTAssertNil(f.engine.state.migrationBackup)
    }

    func testFlagTracksTheSwitch() throws {
        let f = try legacy()
        XCTAssertTrue(try f.inventory(.allProjects).needsMigration)
        try Migration.apply(paths: f.paths, state: &f.engine.state, writer: f.writer)
        XCTAssertFalse(try f.inventory(.allProjects).needsMigration)
    }
}

final class CodexTests: XCTestCase {
    private func setUp(trusted: Bool = true, f: Fixture) throws {
        var text = """
        # my codex config
        [mcp_servers.alpha]
        url = "https://alpha.example/mcp"

        [plugins."docs@openai"]
        enabled = true

        [apps.connector_abcdef123456]

        """
        if trusted { text += "\n[projects.\"\(f.project)\"]\ntrust_level = \"trusted\"\n" }
        try f.write(f.paths.codexConfig, text)
        f.engine.state.harnesses["codex"] = true
    }

    func testProjectOverrideDoesNotTouchGlobal() throws {
        let f = try Fixture()
        try setUp(f: f)
        let before = try String(contentsOf: f.paths.codexConfig, encoding: .utf8)
        let scope = Scope.project(f.project)
        try f.engine.setService(try f.service("Alpha", scope), on: false, scope: scope)
        XCTAssertEqual(try String(contentsOf: f.paths.codexConfig, encoding: .utf8), before)
        let project = TOMLDocument(try String(contentsOf: f.paths.codexProject(f.project), encoding: .utf8))
        XCTAssertEqual(project.bool(["mcp_servers", "alpha"], "enabled"), false)
        XCTAssertFalse(try f.service("Alpha", scope).isOn)
        XCTAssertTrue(try f.service("Alpha", .allProjects).isOn)
    }

    func testResetRemovesTheProjectFile() throws {
        let f = try Fixture()
        try setUp(f: f)
        let scope = Scope.project(f.project)
        try f.engine.setService(try f.service("Docs", scope), on: false, scope: scope)
        XCTAssertFalse(try f.service("Docs", scope).isOn)
        try f.engine.resetService(try f.service("Docs", scope), scope: scope)
        XCTAssertTrue(try f.service("Docs", scope).isOn)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.codexProject(f.project).path))
    }

    func testUntrustedProjectIsLockedAndTrustFixesIt() throws {
        let f = try Fixture()
        try setUp(trusted: false, f: f)
        let scope = Scope.project(f.project)
        let service = try f.service("Alpha", scope)
        XCTAssertEqual(service.active.first?.lock?.fix, .trustCodex)
        try f.engine.trustCodex(project: f.project)
        XCTAssertNil(try f.service("Alpha", scope).active.first?.lock)
        // The comment in the user's file survives.
        XCTAssertTrue(try String(contentsOf: f.paths.codexConfig, encoding: .utf8).contains("# my codex config"))
    }

    func testAddingAClaudeServerToCodexInAProject() throws {
        let f = try Fixture()
        try setUp(f: f)
        try f.writeJSON(f.paths.claudeJson, ["mcpServers": ["beta": ["command": "/bin/beta", "args": ["--a b"]]]])
        let scope = Scope.project(f.project)
        let service = try f.service("Beta", scope)
        let add = try XCTUnwrap(service.controls.first { $0.harness == .codex && !$0.setUp })
        // The main switch doesn't reach a tool that isn't set up.
        XCTAssertFalse(service.switchable.contains(add))
        try f.engine.set(add, on: true, scope: scope)
        let doc = TOMLDocument(try String(contentsOf: f.paths.codexProject(f.project), encoding: .utf8))
        XCTAssertEqual(doc.string(["mcp_servers", "beta"], "command"), "/bin/beta")
        XCTAssertEqual(doc.stringArray(["mcp_servers", "beta"], "args"), ["--a b"])
        XCTAssertEqual(doc.bool(["mcp_servers", "beta"], "enabled"), true)
        XCTAssertTrue(try f.service("Beta", scope).active.contains { $0.harness == .codex })
    }

    func testAppsAreListed() throws {
        let f = try Fixture()
        try setUp(f: f)
        XCTAssertTrue(try f.inventory(.allProjects).services.contains { $0.name == "Codex Connector Abcdef12" })
    }
}

final class SecretsTests: XCTestCase {
    func testPortability() {
        XCTAssertFalse(ServerDefinition(json: ["command": "x", "env": ["TOKEN": "abc"]]).portable)
        XCTAssertFalse(ServerDefinition(json: ["url": "https://a", "headers": ["Authorization": "x"]]).portable)
        XCTAssertFalse(ServerDefinition(json: ["command": "x", "args": ["--api-key=abc"]]).portable)
        XCTAssertFalse(ServerDefinition(json: ["command": "x", "args": ["${CLAUDE_PLUGIN_ROOT}/run"]]).portable)
        XCTAssertTrue(ServerDefinition(json: ["command": "x", "args": ["--port", "3"], "env": [:]]).portable)
        XCTAssertTrue(ServerDefinition(json: ["url": "https://a/mcp"]).portable)
    }

    func testSecretServerIsNeverOfferedToOtherTools() throws {
        let f = try Fixture()
        f.engine.state.harnesses = ["codex": true, "antigravity": true]
        try f.writeJSON(f.paths.claudeJson, ["mcpServers": [
            "safe": ["url": "https://safe.example/mcp"],
            "secret": ["url": "https://secret.example/mcp", "headers": ["Authorization": "Bearer abc"]],
        ]])
        let scope = Scope.project(f.project)
        let secret = try f.service("Secret", scope)
        XCTAssertTrue(secret.controls.allSatisfy { $0.harness == .claude })
        let safe = try f.service("Safe", scope)
        XCTAssertTrue(safe.controls.contains { $0.harness == .codex && !$0.setUp })
        XCTAssertTrue(safe.controls.contains { $0.harness == .antigravity && !$0.setUp })
    }

    func testConnectorsAreNeverCopiedToOtherTools() throws {
        let f = try Fixture()
        f.engine.state.harnesses = ["codex": true, "antigravity": true]
        f.engine.state.connectors["claude.ai Slack"] = "https://mcp.slack.com/mcp"
        XCTAssertTrue(try f.service("Slack", .project(f.project)).controls.allSatisfy { $0.harness == .claude })
    }
}

final class AntigravityTests: XCTestCase {
    func testOffRemovesEntryAndOnRestoresIt() throws {
        let f = try Fixture()
        f.engine.state.harnesses["antigravity"] = true
        try f.writeJSON(f.paths.claudeJson, ["mcpServers": ["alpha": ["url": "https://alpha.example/mcp"]]])
        let scope = Scope.project(f.project)
        let workspace = f.paths.antigravityWorkspace(f.project)

        let add = try XCTUnwrap(try f.service("Alpha", scope).controls.first { $0.harness == .antigravity })
        try f.engine.set(add, on: true, scope: scope)
        var servers = try f.settings(workspace)["mcpServers"] as? [String: [String: Any]]
        XCTAssertEqual(servers?["alpha"]?["serverUrl"] as? String, "https://alpha.example/mcp")
        XCTAssertNil(servers?["alpha"]?["disabled"], "disabled:true doesn't stop a workspace server")

        try f.engine.setService(try f.service("Alpha", scope), on: false, scope: scope)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        let off = try XCTUnwrap(try f.service("Alpha", scope).controls.first { $0.harness == .antigravity })
        XCTAssertTrue(off.setUp, "Turned off is still set up, so the main switch can bring it back")
        XCTAssertFalse(off.on)

        try f.engine.set(off, on: true, scope: scope)
        servers = try f.settings(workspace)["mcpServers"] as? [String: [String: Any]]
        XCTAssertNotNil(servers?["alpha"])
    }

    func testGlobalServerIsLockedInAProject() throws {
        let f = try Fixture()
        f.engine.state.harnesses["antigravity"] = true
        try f.writeJSON(f.paths.antigravityConfig, ["mcpServers": ["gamma": ["serverUrl": "https://gamma.example/mcp"]]])
        let service = try f.service("Gamma", .project(f.project))
        XCTAssertEqual(service.mainState, .locked(on: true))
        let all = try f.service("Gamma", .allProjects)
        XCTAssertEqual(all.mainState, .on)
        try f.engine.setService(all, on: false, scope: .allProjects)
        XCTAssertFalse(try f.service("Gamma", .allProjects).isOn)
    }

    func testEmptyGlobalFileIsFine() throws {
        let f = try Fixture()
        f.engine.state.harnesses["antigravity"] = true
        try f.write(f.paths.antigravityConfig, "")
        XCTAssertNoThrow(try f.inventory(.allProjects))
    }
}

final class CursorTests: XCTestCase {
    func testCursorServersAreReadOnly() throws {
        let f = try Fixture()
        f.engine.state.harnesses["cursor"] = true
        try f.writeJSON(f.paths.cursorConfig, ["mcpServers": ["open-sea": ["url": "https://os.example"]]])
        let service = try f.service("Open Sea", .allProjects)
        XCTAssertEqual(service.mainState, .locked(on: true))
        XCTAssertTrue(service.firstLockReason?.contains("Cursor Settings") == true)
    }
}

final class SkillTests: XCTestCase {
    func testPerProjectStateAndReset() throws {
        let f = try Fixture()
        try f.addSkill("polish", description: String(repeating: "x", count: 400))
        try f.writeJSON(f.paths.claudeSettings, ["skillOverrides": ["polish": "off"]])
        let scope = Scope.project(f.project)
        var skill = try XCTUnwrap(try f.inventory(scope).skills.first)
        XCTAssertEqual(skill.state, .off)
        XCTAssertEqual(skill.tokens, 100)

        try f.engine.setSkill(skill, to: .on, scope: scope)
        skill = try XCTUnwrap(try f.inventory(scope).skills.first)
        XCTAssertEqual(skill.state, .on)
        XCTAssertTrue(skill.setHere)
        let local = try f.settings(f.paths.claudeLocal(f.project))
        XCTAssertEqual((local["skillOverrides"] as? [String: String])?["polish"], "on", "On has to be written, or the default stays off")
        XCTAssertEqual(try f.inventory(.allProjects).skills.first?.state, .off)

        try f.engine.resetSkill(skill, project: f.project)
        XCTAssertEqual(try f.inventory(scope).skills.first?.state, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.claudeLocal(f.project).path))
    }

    func testAuthorLockedSkillIsManualOrOff() throws {
        let f = try Fixture()
        try f.addSkill("deploy", extra: "disable-model-invocation: true\n")
        let skill = try XCTUnwrap(try f.inventory(.allProjects).skills.first)
        XCTAssertEqual(skill.state, .userInvocableOnly)
        XCTAssertEqual(skill.lock, .author)
        XCTAssertEqual(skill.tokens, 0)
    }

    func testBlockScalarDescription() throws {
        let f = try Fixture()
        let url = f.paths.userSkills.appendingPathComponent("long/SKILL.md")
        try f.write(url, "---\nname: long\ndescription: >-\n  first line\n  second line\nallowed-tools: x\n---\nBody\n")
        XCTAssertEqual(SkillFrontmatter(file: url).description, "first line second line")
    }

    func testProjectSkillsAppearOnlyInThatProject() throws {
        let f = try Fixture()
        try f.addSkill("repo-only", under: f.paths.projectSkills(f.project))
        XCTAssertTrue(try f.inventory(.allProjects).skills.isEmpty)
        XCTAssertEqual(try f.inventory(.project(f.project)).skills.first?.source, .project)
    }

    func testTokenTotalCountsOnlyWhatLoads() throws {
        let f = try Fixture()
        try f.addSkill("a", description: String(repeating: "x", count: 400))
        try f.addSkill("b", description: String(repeating: "x", count: 800))
        try f.addSkill("c", description: String(repeating: "x", count: 4000))
        try f.addPlugin("p@m", skills: ["s"])
        try f.writeJSON(f.paths.claudeSettings, ["skillOverrides": ["b": "off"]])
        let inventory = try f.inventory(.allProjects)
        // a = 100, b = off, c capped at 1536 chars = 384, plugin skill description = 3.
        XCTAssertEqual(inventory.skillTokens, 100 + 384 + 3)
    }
}

final class SkillLinkTests: XCTestCase {
    private func linked() throws -> Fixture {
        let f = try Fixture()
        f.engine.state.harnesses["codex"] = true
        try f.addSkill("alpha")
        try f.addSkill("beta")
        try f.writeJSON(f.paths.claudeSettings, ["skillOverrides": ["beta": "off"]])
        return f
    }

    private func links(_ f: Fixture) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: f.paths.agentSkills(f.project).path)) ?? []).sorted()
    }

    func testLinksOnlyAutoSkillsAndKeepsThemInSync() throws {
        let f = try linked()
        let scope = Scope.project(f.project)
        let inventory = try f.inventory(scope)
        let beta = try XCTUnwrap(inventory.skills.first { $0.key == "beta" })
        try f.engine.setSkill(beta, to: .on, scope: scope)
        XCTAssertEqual(links(f), ["alpha", "beta"])

        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: f.paths.agentSkills(f.project).appendingPathComponent("beta").path)
        XCTAssertTrue(dest.hasSuffix(".claude/skills/beta"))

        try f.engine.setSkill(beta, to: .userInvocableOnly, scope: scope)
        XCTAssertEqual(links(f), ["alpha"])
    }

    func testNeverRemovesRealFoldersOrForeignLinks() throws {
        let f = try linked()
        let dir = f.paths.agentSkills(f.project)
        try f.write(dir.appendingPathComponent("repo-skill/SKILL.md"), "real")
        // Same name as a skill that's off, but a real folder owned by the repo.
        try f.write(dir.appendingPathComponent("beta/SKILL.md"), "real beta")
        let foreign = f.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("foreign"), withDestinationURL: foreign)

        let scope = Scope.project(f.project)
        let alpha = try XCTUnwrap(try f.inventory(scope).skills.first { $0.key == "alpha" })
        try f.engine.setSkill(alpha, to: .off, scope: scope)

        XCTAssertEqual(links(f), ["beta", "foreign", "repo-skill"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("beta/SKILL.md"), encoding: .utf8), "real beta")
    }

    func testRealFolderIsNotReplacedWhenSkillGoesOn() throws {
        let f = try linked()
        let dir = f.paths.agentSkills(f.project)
        try f.write(dir.appendingPathComponent("alpha/SKILL.md"), "real alpha")
        let scope = Scope.project(f.project)
        let beta = try XCTUnwrap(try f.inventory(scope).skills.first { $0.key == "beta" })
        try f.engine.setSkill(beta, to: .on, scope: scope)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("alpha/SKILL.md"), encoding: .utf8), "real alpha")
    }

    func testDefaultChangeReachesLinkedProjects() throws {
        let f = try linked()
        let scope = Scope.project(f.project)
        let alpha = try XCTUnwrap(try f.inventory(scope).skills.first { $0.key == "alpha" })
        try f.engine.setSkill(alpha, to: .on, scope: scope)
        XCTAssertEqual(links(f), ["alpha"])
        let beta = try XCTUnwrap(try f.inventory(.allProjects).skills.first { $0.key == "beta" })
        try f.engine.setSkill(beta, to: .on, scope: .allProjects)
        XCTAssertEqual(links(f), ["alpha", "beta"])
    }

    func testNoLinksWhenNoOtherToolIsManaged() throws {
        let f = try Fixture()
        try f.addSkill("alpha")
        let scope = Scope.project(f.project)
        let alpha = try XCTUnwrap(try f.inventory(scope).skills.first)
        try f.engine.setSkill(alpha, to: .on, scope: scope)
        XCTAssertEqual(links(f), [])
    }

    func testUndoRestoresLinks() throws {
        let f = try linked()
        let scope = Scope.project(f.project)
        let beta = try XCTUnwrap(try f.inventory(scope).skills.first { $0.key == "beta" })
        try f.engine.setSkill(beta, to: .on, scope: scope)
        XCTAssertEqual(links(f), ["alpha", "beta"])
        try f.writer.undo(f.writer.finishChange())
        XCTAssertEqual(links(f), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.claudeLocal(f.project).path))
    }
}

final class PresetTests: XCTestCase {
    func testSnapshotAndApplyToAnotherProject() throws {
        let f = try Fixture()
        try f.writeJSON(f.paths.claudeJson, ["mcpServers": ["alpha": ["url": "https://alpha.example/mcp"]]])
        try f.writeJSON(f.paths.claudeSettings, ["allowedMcpServers": []])
        try f.addSkill("polish")
        try f.addPlugin("vercel@official")

        let source = Scope.project(f.project)
        try f.engine.setService(try f.service("Alpha", source), on: true, scope: source)
        try f.engine.setService(try f.service("Vercel", source), on: false, scope: source)
        try f.engine.setSkill(try XCTUnwrap(try f.inventory(source).skills.first), to: .off, scope: source)
        let preset = f.engine.snapshotPreset(name: "Design", inventory: try f.inventory(source))

        let other = f.root.appendingPathComponent("work/other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let target = Scope.project(other.path)
        try f.engine.apply(preset, scope: target, inventory: try f.inventory(target))

        XCTAssertTrue(try f.service("Alpha", target).isOn)
        XCTAssertFalse(try f.service("Vercel", target).isOn)
        XCTAssertEqual(try f.inventory(target).skills.first?.state, .off)
    }

    func testResetProjectClearsEverything() throws {
        let f = try Fixture()
        try f.writeJSON(f.paths.claudeJson, ["mcpServers": ["alpha": ["url": "https://alpha.example/mcp"]]])
        try f.writeJSON(f.paths.claudeSettings, ["allowedMcpServers": []])
        try f.addSkill("polish")
        let scope = Scope.project(f.project)
        try f.engine.setService(try f.service("Alpha", scope), on: true, scope: scope)
        try f.engine.setSkill(try XCTUnwrap(try f.inventory(scope).skills.first), to: .off, scope: scope)
        try f.engine.resetProject(f.project, inventory: try f.inventory(scope))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.claudeLocal(f.project).path))
    }
}

final class ProjectCatalogTests: XCTestCase {
    func testOwnerPicksDeepestAndRespectsBoundaries() {
        let projects = ["/w/app", "/w/app/site", "/w/application"]
        XCTAssertEqual(ProjectCatalog.owner(of: "/w/app/site/src", among: projects), "/w/app/site")
        XCTAssertEqual(ProjectCatalog.owner(of: "/w/app/lib", among: projects), "/w/app")
        XCTAssertEqual(ProjectCatalog.owner(of: "/w/app", among: projects), "/w/app")
        XCTAssertEqual(ProjectCatalog.owner(of: "/w/application/x", among: projects), "/w/application")
        XCTAssertNil(ProjectCatalog.owner(of: "/w/other", among: projects))
    }

    func testCatalogSkipsHomeTempAndMissingFolders() throws {
        let f = try Fixture()
        let scratch = f.root.appendingPathComponent("scratch/run")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try f.writeJSON(f.paths.claudeJson, ["projects": [
            f.project: [:],
            f.home.path: [:],
            scratch.path: [:],
            "/no/such/folder": [:],
        ]])
        let scratchRoot = f.root.appendingPathComponent("scratch").path + "/"
        XCTAssertEqual(ProjectCatalog.load(f.paths, state: AppState(), scratchFolders: [scratchRoot]).map(\.path), [f.project])
    }

    func testMostRecentFirst() throws {
        let f = try Fixture()
        let older = f.root.appendingPathComponent("work/older")
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try f.writeJSON(f.paths.claudeJson, ["projects": [f.project: [:], older.path: [:]]])
        func encoded(_ path: String) -> URL {
            f.paths.claudeSessions.appendingPathComponent(String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" }))
        }
        for (path, age) in [(f.project, 5000.0), (older.path, 10.0)] {
            let url = encoded(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        XCTAssertEqual(ProjectCatalog.load(f.paths, state: AppState(), scratchFolders: []).first?.path, older.path)
    }
}

final class GitExcludeTests: XCTestCase {
    private func repo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loadout-git-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = runLoginShell("git -C \(shellQuote(dir.path)) init -q")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func exclude(_ dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
    }

    func testAddsOnceAndHidesFromStatus() throws {
        let dir = try repo()
        let file = dir.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x = 1\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(GitExclude.exclude(".codex/config.toml", in: dir))
        GitExclude.exclude(".codex/config.toml", in: dir)
        let count = try exclude(dir).components(separatedBy: "/.codex/config.toml").count - 1
        XCTAssertEqual(count, 1)
        let status = runLoginShell("git -C \(shellQuote(dir.path)) status --porcelain").output
        XCTAssertFalse(status.contains(".codex"))
    }

    func testTrackedFileIsNotExcluded() throws {
        let dir = try repo()
        let q = shellQuote(dir.path)
        try "x\n".write(to: dir.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = runLoginShell("git -C \(q) add tracked.txt")
        XCTAssertTrue(GitExclude.exclude("tracked.txt", in: dir))
        XCTAssertFalse(try exclude(dir).contains("tracked.txt"))
    }

    func testOutsideARepoIsHarmless() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loadout-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(GitExclude.exclude("anything", in: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path))
    }
}

final class PortGroupTests: XCTestCase {
    private func port(_ number: Int, _ cwd: String?) -> PortEntry {
        PortEntry(
            port: number, pid: 1, processName: "node", command: "", cwd: cwd, projectName: nil,
            framework: nil, uptime: nil, isZombie: false, isOrphaned: false
        )
    }

    func testGroupsByDeepestProjectWithOtherLast() {
        let groups = PortGroup.make(
            from: [
                port(3000, "/h/w/app"),
                port(3001, "/h/w/app/site"),
                port(3002, "/h/w/app/lib"),
                port(4000, "/h/w/unknown"),
                port(5000, "/h"),
                port(5001, nil),
            ],
            known: ["/h", "/h/w/app", "/h/w/app/site"],
            home: "/h"
        )
        XCTAssertEqual(groups.map(\.name), ["app", "site", "unknown", "Other"])
        XCTAssertEqual(groups[0].ports.map(\.port), [3000, 3002])
        XCTAssertNil(groups[0].subfolder(of: groups[0].ports[0]))
        XCTAssertEqual(groups[0].subfolder(of: groups[0].ports[1]), "lib")
        XCTAssertEqual(groups[3].ports.map(\.port), [5000, 5001])
    }
}

final class AppStoreTests: XCTestCase {
    @MainActor func testUndoRestoresFilesAndLoadoutState() throws {
        let f = try Fixture()
        try f.writeJSON(f.paths.claudeJson, ["mcpServers": ["alpha": ["url": "https://alpha.example/mcp"]]])
        try f.writeJSON(f.paths.claudeSettings, ["allowedMcpServers": []])
        var state = AppState()
        state.harnesses = ["antigravity": true]
        try state.save(f.paths)

        let store = AppStore(home: f.home, initialScope: .project(f.project))
        func service() throws -> Service { try XCTUnwrap(store.inventory.services.first { $0.name == "Alpha" }) }
        let add = try XCTUnwrap(try service().controls.first { $0.harness == .antigravity })
        store.set(add, in: try service(), on: true)
        let on = try XCTUnwrap(try service().controls.first { $0.harness == .antigravity })
        XCTAssertTrue(on.on)
        store.set(on, in: try service(), on: false)
        XCTAssertNotNil(store.state.antigravityOff[f.project]?["alpha"])

        store.undo()
        XCTAssertNil(store.state.antigravityOff[f.project], "Undo must put Loadout's own state back too")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.paths.antigravityWorkspace(f.project).path))
        store.undo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.antigravityWorkspace(f.project).path))
        XCTAssertFalse(store.canUndo)
    }

    @MainActor func testFailureLeavesNothingBehind() throws {
        let f = try Fixture()
        try f.writeJSON(f.paths.claudeJson, ["mcpServers": ["alpha": ["url": "https://alpha.example/mcp"]]])
        try f.writeJSON(f.paths.claudeSettings, ["allowedMcpServers": []])
        try f.addPlugin("alpha@m")
        let store = AppStore(home: f.home, initialScope: .project(f.project))
        // A broken file makes the write fail after nothing has changed.
        let service = try XCTUnwrap(store.inventory.services.first { $0.name == "Alpha" })
        try f.write(f.paths.folder(f.project).appendingPathComponent(".claude/settings.local.json"), "{ broken")
        store.setService(service, on: true)
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.canUndo)
        XCTAssertEqual(try String(contentsOf: f.paths.claudeLocal(f.project), encoding: .utf8), "{ broken")
    }

    @MainActor func testSwitchWaitsForConnectorDiscovery() throws {
        let f = try Fixture()
        try f.writeJSON(f.paths.claudeJson, ["mcpServers": ["alpha": ["url": "https://alpha.example/mcp"]]])
        let store = AppStore(readOnly: true, home: f.home)
        XCTAssertFalse(store.canMigrate, "Connectors aren't known yet, so switching could turn some off")
    }
}
