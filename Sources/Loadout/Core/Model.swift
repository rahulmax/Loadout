import Foundation

/// What a switch writes to: the default every project inherits, or one project.
enum Scope: Hashable {
    case allProjects
    case project(String)

    var projectPath: String? {
        if case .project(let path) = self { return path }
        return nil
    }
}

enum Harness: String, CaseIterable, Codable, Identifiable {
    case claude, codex, antigravity, cursor

    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .cursor: return "Cursor"
        }
    }
}

/// Every path Loadout reads or writes, rooted at a home folder so tests can use a fake one.
struct Paths {
    let home: URL

    private func at(_ relative: String) -> URL { home.appendingPathComponent(relative) }

    var claudeSettings: URL { at(".claude/settings.json") }
    var claudeJson: URL { at(".claude.json") }
    var installedPlugins: URL { at(".claude/plugins/installed_plugins.json") }
    var userSkills: URL { at(".claude/skills") }
    var claudeSessions: URL { at(".claude/projects") }
    var codexDir: URL { at(".codex") }
    var codexConfig: URL { at(".codex/config.toml") }
    var antigravityDir: URL { at(".gemini/config") }
    var antigravityConfig: URL { at(".gemini/config/mcp_config.json") }
    var cursorDir: URL { at(".cursor") }
    var cursorConfig: URL { at(".cursor/mcp.json") }
    var appSupport: URL { at("Library/Application Support/Loadout") }
    var stateFile: URL { appSupport.appendingPathComponent("state.json") }
    var backups: URL { appSupport.appendingPathComponent("backups") }
    /// Discovery runs from here: in the home folder, `.claude/settings.json` would read
    /// as project settings too, and the user allow and deny lists would apply.
    var discoveryFolder: URL { appSupport.appendingPathComponent("discovery") }
    /// Debug fixtures can supply `claude mcp list` output instead of running the CLI.
    var discoveryFixture: URL { at("mcp-list.txt") }

    func folder(_ project: String) -> URL { URL(fileURLWithPath: project) }
    func claudeLocal(_ project: String) -> URL { folder(project).appendingPathComponent(".claude/settings.local.json") }
    func claudeShared(_ project: String) -> URL { folder(project).appendingPathComponent(".claude/settings.json") }
    func projectSkills(_ project: String) -> URL { folder(project).appendingPathComponent(".claude/skills") }
    func projectMcp(_ project: String) -> URL { folder(project).appendingPathComponent(".mcp.json") }
    func codexProject(_ project: String) -> URL { folder(project).appendingPathComponent(".codex/config.toml") }
    func antigravityWorkspace(_ project: String) -> URL { folder(project).appendingPathComponent(".agents/mcp_config.json") }
    func agentSkills(_ project: String) -> URL { folder(project).appendingPathComponent(".agents/skills") }
    func cursorProject(_ project: String) -> URL { folder(project).appendingPathComponent(".cursor/mcp.json") }
}

// MARK: - Server definitions

struct ServerDefinition: Hashable {
    var url: String?
    var command: String?
    var args: [String] = []
    /// False when copying it to another tool would spread a secret or break a path.
    var portable = true

    var commandLine: [String]? { command.map { [$0] + args } }

    var summary: String {
        if let url { return url }
        return (commandLine ?? []).joined(separator: " ")
    }

    var host: String? {
        guard let url, let components = URLComponents(string: url), let host = components.host else { return nil }
        if let port = components.port { return "\(host):\(port)" }
        return host
    }

    /// Reads a server from any tool's JSON. Claude and Cursor use `url`, Antigravity `serverUrl`.
    init(json: [String: Any]) {
        url = json["url"] as? String ?? json["serverUrl"] as? String
        command = json["command"] as? String
        args = json["args"] as? [String] ?? []
        let hasEnv = !(json["env"] as? [String: Any] ?? [:]).isEmpty
        let hasHeaders = !(json["headers"] as? [String: Any] ?? [:]).isEmpty
        portable = !hasEnv && !hasHeaders && Self.argsArePortable(args, url: url)
    }

    init(url: String? = nil, command: String? = nil, args: [String] = [], portable: Bool = true) {
        self.url = url
        self.command = command
        self.args = args
        self.portable = portable
    }

    /// Plugin-relative paths break elsewhere, and a token in the arguments must not spread.
    static func argsArePortable(_ args: [String], url: String?) -> Bool {
        let joined = (args + [url ?? ""]).joined(separator: " ")
        if joined.contains("${") { return false }
        return joined.range(of: #"(?i)(token|secret|password|api[-_]?key)"#, options: .regularExpression) == nil
    }

    var antigravityJSON: [String: Any] {
        if let url { return ["serverUrl": url] }
        var json: [String: Any] = ["command": command ?? ""]
        if !args.isEmpty { json["args"] = args }
        return json
    }
}

// MARK: - Claude Code allow and deny rules

/// One entry in `allowedMcpServers` or `deniedMcpServers`.
enum ClaudeRule: Hashable {
    case url(String)
    case name(String)
    case command([String])

    var json: [String: Any] {
        switch self {
        case .url(let value): return ["serverUrl": value]
        case .name(let value): return ["serverName": value]
        case .command(let value): return ["serverCommand": value]
        }
    }

    /// `https://mcp.figma.com/*` covers every copy of a server, whichever source it came
    /// from, and also matches a URL with no path. The Anthropic host serves unrelated
    /// things, so it gets an exact match.
    static func urlPattern(_ url: String) -> String {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme, let host = components.host,
              host != "api.anthropic.com" else { return url }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)/*"
    }
}

/// Everything known about one server as Claude Code sees it, across sources.
struct ClaudeServerRef: Hashable {
    /// Names as they appear in `/mcp` and in deny entries.
    var names: Set<String>
    var urls: Set<String>
    var command: [String]?
    /// True for sources a name-based allow entry works on. Testing showed it doesn't
    /// work for claude.ai connectors or plugin servers.
    var allowableNames: Set<String>
    var allowRule: ClaudeRule?
    var denyRule: ClaudeRule
    var ownerPlugins: Set<String> = []
    var hasStandaloneSource = false
}

enum ClaudeRules {
    /// `*` is the only wildcard.
    static func glob(_ pattern: String, matches value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        return value.range(of: "^\(escaped)$", options: .regularExpression) != nil
    }

    static func entry(_ entry: [String: Any], matches ref: ClaudeServerRef, forAllow: Bool) -> Bool {
        if let name = entry["serverName"] as? String {
            return (forAllow ? ref.allowableNames : ref.names).contains(name)
        }
        if let pattern = entry["serverUrl"] as? String {
            return ref.urls.contains { glob(pattern, matches: $0) }
        }
        if let command = entry["serverCommand"] as? [String] {
            return ref.command == command
        }
        return false
    }

    static func anyMatch(_ entries: [[String: Any]], _ ref: ClaudeServerRef, forAllow: Bool) -> Bool {
        entries.contains { entry($0, matches: ref, forAllow: forAllow) }
    }
}

/// The Claude Code settings that apply to one scope.
struct ClaudeSettings {
    let user: [String: Any]
    let shared: [String: Any]
    let local: [String: Any]
    let projectEntry: [String: Any]

    private func list(_ file: [String: Any], _ key: String) -> [[String: Any]] {
        file[key] as? [[String: Any]] ?? []
    }

    var hasUserAllowlist: Bool { user["allowedMcpServers"] != nil }
    var allowlistActive: Bool {
        user["allowedMcpServers"] != nil || shared["allowedMcpServers"] != nil || local["allowedMcpServers"] != nil
    }

    var slashDisabled: Set<String> { Set(projectEntry["disabledMcpServers"] as? [String] ?? []) }

    func deniedByUser(_ ref: ClaudeServerRef) -> Bool {
        ClaudeRules.anyMatch(list(user, "deniedMcpServers"), ref, forAllow: false)
    }

    func deniedByShared(_ ref: ClaudeServerRef) -> Bool {
        ClaudeRules.anyMatch(list(shared, "deniedMcpServers"), ref, forAllow: false)
    }

    func deniedHere(_ ref: ClaudeServerRef) -> Bool {
        ClaudeRules.anyMatch(list(local, "deniedMcpServers"), ref, forAllow: false)
    }

    func allowedAbove(_ ref: ClaudeServerRef) -> Bool {
        ClaudeRules.anyMatch(list(user, "allowedMcpServers"), ref, forAllow: true)
            || ClaudeRules.anyMatch(list(shared, "allowedMcpServers"), ref, forAllow: true)
    }

    func allowedHere(_ ref: ClaudeServerRef) -> Bool {
        ClaudeRules.anyMatch(list(local, "allowedMcpServers"), ref, forAllow: true)
    }

    func slashDisabledHere(_ ref: ClaudeServerRef) -> Bool {
        !slashDisabled.isDisjoint(with: ref.names)
    }

    /// Deny always wins. With no allowlist anywhere, everything else is allowed.
    func isOn(_ ref: ClaudeServerRef) -> Bool {
        if deniedByUser(ref) || deniedByShared(ref) || deniedHere(ref) || slashDisabledHere(ref) { return false }
        return !allowlistActive || allowedAbove(ref) || allowedHere(ref)
    }

    func pluginEnabled(_ id: String) -> Bool {
        for file in [local, shared, user] {
            if let value = (file["enabledPlugins"] as? [String: Bool])?[id] { return value }
        }
        return true
    }

    func pluginSetLocally(_ id: String) -> Bool {
        (local["enabledPlugins"] as? [String: Bool])?[id] != nil
    }

    func pluginSetHere(_ id: String) -> Bool {
        (local["enabledPlugins"] as? [String: Bool])?[id] != nil
            || (shared["enabledPlugins"] as? [String: Bool])?[id] != nil
    }
}

// MARK: - Controls and services

enum ControlTarget: Hashable {
    case claudePlugin(String)
    case claudeServer(ClaudeServerRef)
    case codexPlugin(String)
    case codexApp(String)
    case codexServer(name: String, definition: ServerDefinition?, definedGlobally: Bool)
    case antigravityServer(name: String, definition: ServerDefinition?, definedGlobally: Bool)
    /// Cursor keeps server on/off in its app state, so Loadout can only list these.
    case cursorServer(String)
}

/// Why a switch can't be used, and what would fix it.
struct ControlLock: Hashable {
    enum Fix: Hashable {
        case trustCodex
        case switchToPerProject
    }

    let reason: String
    var fix: Fix?
}

/// One independently switchable thing: a plugin, or a server in one tool.
struct Control: Identifiable, Hashable {
    let id: String
    let harness: Harness
    let label: String
    let target: ControlTarget
    let on: Bool
    /// False when this tool doesn't have the service yet. It can be added.
    let setUp: Bool
    /// True when this project has its own choice, so there's something to reset.
    let setHere: Bool
    let lock: ControlLock?
    var status: String?
    /// Grouping keys: same name, or same URL host, means same service.
    var groupKeys: Set<String> = []
    var definition: ServerDefinition?
    var kind: String = "MCP"
}

struct PluginSkillInfo: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let name: String
    let tokens: Int
    let enabled: Bool
}

enum MainState: Hashable {
    case on, off, mixed
    /// Nothing here can be changed from Loadout. The row's control locks say why.
    case locked(on: Bool)
}

struct Service: Identifiable, Hashable {
    let id: String
    let name: String
    var controls: [Control]
    var pluginSkills: [PluginSkillInfo] = []
    /// Folder names of projects that set their own choice. Filled in All projects view.
    var setInProjects: [String] = []

    var active: [Control] { controls.filter(\.setUp) }
    var switchable: [Control] { active.filter { $0.lock == nil } }

    var mainState: MainState {
        let items = switchable
        guard !items.isEmpty else { return .locked(on: active.first?.on ?? false) }
        let onCount = items.filter(\.on).count
        if onCount == 0 { return .off }
        return onCount == items.count ? .on : .mixed
    }

    var isOn: Bool {
        switch mainState {
        case .on, .mixed: return true
        case .off: return false
        case .locked(let on): return on
        }
    }

    var setHere: Bool { controls.contains(where: \.setHere) }

    var tokens: Int { pluginSkills.reduce(0) { $0 + $1.tokens } }

    /// The harnesses the service exists in, in display order.
    var harnesses: [Harness] {
        Harness.allCases.filter { harness in active.contains { $0.harness == harness } }
    }

    /// "Plugin + MCP + claude.ai", with no repeats.
    var kindSummary: String {
        var kinds: [String] = []
        for control in active where !kinds.contains(control.kind) { kinds.append(control.kind) }
        return kinds.joined(separator: " + ")
    }

    var firstLockReason: String? { active.first(where: { $0.lock != nil })?.lock?.reason }
}

// MARK: - Skills

enum SkillOverride: String, CaseIterable, Identifiable, Codable {
    case on
    case nameOnly = "name-only"
    case userInvocableOnly = "user-invocable-only"
    case off

    var id: String { rawValue }

    /// Plain label. The stored value only ever shows in a tooltip.
    var label: String {
        switch self {
        case .on: return "Auto"
        case .nameOnly: return "Name only"
        case .userInvocableOnly: return "Manual"
        case .off: return "Off"
        }
    }

    var explanation: String {
        switch self {
        case .on: return "Auto: the agent sees its description and can pick it. Its instructions load only when used."
        case .nameOnly: return "Name only: the agent sees just the name, so it has little to go on. Costs almost nothing."
        case .userInvocableOnly: return "Manual: hidden from the agent. It runs only when you type /name."
        case .off: return "Off: hidden from the agent and from the / menu."
        }
    }
}

/// Why a skill's state can't be fully set.
enum SkillLock: Hashable {
    /// The skill sets `disable-model-invocation`, so it's Manual unless turned off.
    case author
}

enum SkillSource: Hashable {
    case user
    case project
}

/// A project whose own settings give a skill a different state than the default.
struct ProjectOverride: Hashable {
    let project: String
    let state: SkillOverride
}

struct SkillItem: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let source: SkillSource
    let folder: URL
    /// Estimated tokens for the always-loaded description.
    let tokens: Int
    let lock: SkillLock?
    let state: SkillOverride
    let setHere: Bool
    var projects: [ProjectOverride] = []
}

// MARK: - Inventory

struct Inventory {
    var services: [Service] = []
    var skills: [SkillItem] = []
    /// `plugin:skill` keys in `skillOverrides`. Claude Code never reads them.
    var deadOverrideKeys: [String] = []
    /// True until the user switches Claude Code to default-off.
    var needsMigration = false

    /// Estimated always-on tokens from the user's and project's own skills.
    var ownSkillTokens: Int {
        skills.reduce(0) { total, skill in
            switch skill.state {
            case .on: return total + skill.tokens
            case .nameOnly: return total + max(1, skill.key.count / 4)
            case .userInvocableOnly, .off: return total
            }
        }
    }

    /// The same, plus the skills of plugins that are on in the chosen scope.
    var skillTokens: Int {
        let own = ownSkillTokens
        let plugins = services.flatMap(\.pluginSkills).filter(\.enabled).reduce(0) { $0 + $1.tokens }
        return own + plugins
    }
}

struct KnownProject: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var name: String { (path as NSString).lastPathComponent }
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
    let lastUsed: Date?
}

// MARK: - Saved state

struct Preset: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var services: [String: Bool]
    var skills: [String: SkillOverride]
}

/// Only what no tool's own config can hold. On/off choices live in each tool's files.
struct AppState: Codable {
    var harnesses: [String: Bool] = [:]
    var presets: [Preset] = []
    /// Connector name → URL, remembered so a connector stays listed when it's offline.
    var connectors: [String: String] = [:]
    var connectorStatus: [String: String] = [:]
    /// Projects that have skills linked for other tools, kept in sync on default changes.
    var linkedProjects: [String] = []
    /// Project → Antigravity servers turned off there. Antigravity has no working
    /// per-project off, so the entry is removed and remembered here to restore on On.
    var antigravityOff: [String: [String: StoredDefinition]] = [:]
    var migrationBackup: String?
    var selectedProject: String?
    var extraProjects: [String] = []

    struct StoredDefinition: Codable {
        var url: String?
        var command: String?
        var args: [String]

        var definition: ServerDefinition { ServerDefinition(url: url, command: command, args: args) }
    }

    static func load(_ paths: Paths) -> AppState {
        guard let data = try? Data(contentsOf: paths.stateFile),
              let state = try? JSONDecoder().decode(AppState.self, from: data) else { return AppState() }
        return state
    }

    func save(_ paths: Paths) throws {
        try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: paths.stateFile, options: .atomic)
    }

    func manages(_ harness: Harness, paths: Paths) -> Bool {
        if harness == .claude { return true }
        if let choice = harnesses[harness.rawValue] { return choice }
        let fm = FileManager.default
        switch harness {
        case .claude: return true
        case .codex: return fm.fileExists(atPath: paths.codexDir.path)
        case .antigravity: return fm.fileExists(atPath: paths.antigravityDir.path)
        case .cursor: return fm.fileExists(atPath: paths.cursorDir.path)
        }
    }
}
