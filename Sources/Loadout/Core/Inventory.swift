import Foundation

// MARK: - Discovery

struct ParsedMcpEntry: Hashable {
    let name: String
    let url: String
    let status: String
}

/// Parses `claude mcp list`: `name: target (HTTP) - ✔ Connected`.
func parseMcpList(_ text: String) -> [ParsedMcpEntry] {
    var result: [ParsedMcpEntry] = []
    for rawLine in text.split(separator: "\n") {
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty,
              !line.lowercased().contains("checking mcp"),
              line.contains(": "),
              // The last " - " separates status. URLs can contain dashes.
              let dash = line.range(of: " - ", options: .backwards),
              let colon = line[..<dash.lowerBound].range(of: ": ")
        else { continue }
        let status = String(line[dash.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "✓✔!✘✗ ").union(.whitespaces))
        let name = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
        var details = String(line[colon.upperBound..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
        if let range = details.range(of: #"\s+\((HTTP|SSE|stdio)\)$"#, options: [.regularExpression, .caseInsensitive]) {
            details.removeSubrange(range)
        }
        result.append(ParsedMcpEntry(name: name, url: details, status: status))
    }
    return result
}

/// Lists every connector on the account, with its URL. Skipping user settings means
/// the user allow and deny lists can't hide any. Runs from a folder Loadout owns.
func discoverConnectors(_ paths: Paths) -> [ParsedMcpEntry]? {
    #if DEBUG
    if let text = try? String(contentsOf: paths.discoveryFixture, encoding: .utf8) {
        return parseMcpList(text).filter { $0.name.hasPrefix("claude.ai ") }
    }
    #endif
    // A fake home (fixtures, tests) must never reach the real account through the CLI.
    let realHome = canonicalPath(FileManager.default.homeDirectoryForCurrentUser.path)
    guard canonicalPath(paths.home.path) == realHome else { return [] }
    try? FileManager.default.createDirectory(at: paths.discoveryFolder, withIntermediateDirectories: true)
    let result = runLoginShell("claude --setting-sources project,local mcp list", cwd: paths.discoveryFolder)
    guard result.status == 0 else { return nil }
    return parseMcpList(result.output).filter { $0.name.hasPrefix("claude.ai ") }
}

// MARK: - Skill frontmatter

struct SkillFrontmatter {
    var description = ""
    var disablesModelInvocation = false

    /// Claude Code caps a listed description at 1,536 characters.
    var tokens: Int { max(1, min(description.count, 1536) / 4) }

    init(file: URL) {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.hasPrefix("---") else { return }
        var inDescription = false
        var collected: [String] = []
        for line in text.components(separatedBy: "\n").dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            let continuation = line.hasPrefix(" ") || line.hasPrefix("\t")
            if inDescription && continuation {
                collected.append(trimmed)
                continue
            }
            inDescription = false
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if key == "description" {
                inDescription = true
                if !["|", ">", "|-", ">-"].contains(value) { collected.append(value) }
            } else if key == "disable-model-invocation" {
                disablesModelInvocation = value.lowercased() == "true"
            }
        }
        description = collected.joined(separator: " ")
    }
}

func skillFolders(in dir: URL) -> [URL] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
    return entries.filter {
        fm.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path)
    }
}

// MARK: - Projects

enum ProjectCatalog {
    /// Project folders from Claude Code and Codex history, most recently used first.
    static func load(
        _ paths: Paths,
        state: AppState,
        scratchFolders: [String] = ["/tmp/", "/private/tmp/", "/private/var/", "/var/folders/"]
    ) -> [KnownProject] {
        let fm = FileManager.default
        var candidates = Set(state.extraProjects)
        if let claude = try? readJSONObject(paths.claudeJson),
           let projects = claude["projects"] as? [String: Any] {
            candidates.formUnion(projects.keys)
        }
        let codex = TOMLDocument((try? String(contentsOf: paths.codexConfig, encoding: .utf8)) ?? "")
        let trustedInCodex = Set(codex.children(of: "projects"))
        candidates.formUnion(trustedInCodex)
        let shown = Harness.allCases.filter { state.manages($0, paths: paths) }
        let markers = shown.flatMap(\.projectMarkers)
        // Looking inside these can bring up a macOS permission prompt, so only a folder
        // the user chose counts there.
        let protected = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]
            .map { paths.home.appendingPathComponent($0).path + "/" }

        let home = canonicalPath(paths.home.path)
        let excluded = scratchFolders + [paths.appSupport.path + "/"]
        var result: [KnownProject] = []
        for path in candidates {
            var isDir: ObjCBool = false
            guard path != home, path != "/",
                  !excluded.contains(where: { path.hasPrefix($0) || path + "/" == $0 }),
                  fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            let isProject = state.extraProjects.contains(path)
                || (shown.contains(.codex) && trustedInCodex.contains(path))
                || (!protected.contains { path.hasPrefix($0) }
                    && markers.contains { fm.fileExists(atPath: (path as NSString).appendingPathComponent($0)) })
            result.append(KnownProject(path: path, lastUsed: lastUsed(path, paths: paths), isProject: isProject))
        }
        let sorted = result.sorted {
            switch ($0.lastUsed, $1.lastUsed) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.path.lowercased() < $1.path.lowercased()
            }
        }
        return uniqueFolders(sorted)
    }

    /// On a case-insensitive disk `Acme` and `acme` are one folder that history
    /// lists twice. The same file number shows it. Sorted input means the recent one stays.
    private static func uniqueFolders(_ projects: [KnownProject]) -> [KnownProject] {
        var seen = Set<String>()
        return projects.filter { project in
            // Plain stat on purpose. FileManager's attributes also read extended
            // attributes, and that stalls on folders macOS protects, like Downloads.
            var info = stat()
            guard stat(project.path, &info) == 0 else { return true }
            return seen.insert("\(info.st_dev):\(info.st_ino)").inserted
        }
    }

    /// Claude Code keeps sessions in a folder named after the path, with everything
    /// but letters and digits turned into dashes. Its last change is the last use.
    private static func lastUsed(_ path: String, paths: Paths) -> Date? {
        let encoded = String(path.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "-"
        })
        let url = paths.claudeSessions.appendingPathComponent(encoded)
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// The known project a working directory belongs to: the deepest one containing it.
    /// The home folder never counts, or everything would land in it.
    static func owner(of cwd: String, among projects: [String]) -> String? {
        projects
            .filter { cwd == $0 || cwd.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
    }
}

// MARK: - Loader

struct InventoryLoader {
    let paths: Paths
    let state: AppState

    /// URLs for connectors never seen by discovery but named in older settings.
    private static let knownConnectorUrls: [String: String] = [
        "Gmail": "https://gmailmcp.googleapis.com/mcp/v1",
        "Google Calendar": "https://calendarmcp.googleapis.com/mcp/v1",
        "Google Drive": "https://drivemcp.googleapis.com/mcp/v1",
        "Slack": "https://mcp.slack.com/mcp",
        "Miro": "https://mcp.miro.com",
        "Figma": "https://mcp.figma.com/mcp",
    ]

    /// Projects whose settings are read per reload, so a huge history can't slow the panel.
    private static let projectScanLimit = 200

    func claudeSettings(scope: Scope) throws -> ClaudeSettings {
        let user = try readJSONObject(paths.claudeSettings)
        guard let project = scope.projectPath else {
            return ClaudeSettings(user: user, shared: [:], local: [:], projectEntry: [:])
        }
        let claude = try readJSONObject(paths.claudeJson)
        let entry = (claude["projects"] as? [String: [String: Any]])?[project] ?? [:]
        return ClaudeSettings(
            user: user,
            shared: isHome(project) ? [:] : ((try? readJSONObject(paths.claudeShared(project))) ?? [:]),
            local: (try? readJSONObject(paths.claudeLocal(project))) ?? [:],
            projectEntry: entry
        )
    }

    private func isHome(_ project: String) -> Bool {
        canonicalPath(project) == canonicalPath(paths.home.path)
    }

    func load(scope: Scope) throws -> Inventory {
        let settings = try claudeSettings(scope: scope)
        var skillsByKey: [String: [PluginSkillInfo]] = [:]
        let showsClaude = state.manages(.claude, paths: paths)
        // Hidden tools are read too, for their numbers. A broken file in one shouldn't
        // stop the panel when that tool isn't even showing.
        var collected: [String: [PluginSkillInfo]] = [:]
        let claude = showsClaude
            ? try claudeControls(scope: scope, settings: settings, pluginSkills: &collected)
            : (try? claudeControls(scope: scope, settings: settings, pluginSkills: &collected)) ?? []
        if showsClaude { skillsByKey = collected }
        let available = { (harness: Harness) in
            state.manages(harness, paths: paths) || state.isInstalled(harness, paths: paths)
        }
        let byHarness: [Harness: [Control]] = [
            .claude: claude,
            .codex: available(.codex) ? codexControls(scope: scope) : [],
            .antigravity: available(.antigravity) ? antigravityControls(scope: scope) : [],
            .cursor: available(.cursor) ? cursorControls(scope: scope) : [],
        ]
        let controls = Harness.allCases
            .filter { state.manages($0, paths: paths) }
            .flatMap { byHarness[$0] ?? [] }
        let skills = loadSkills(scope: scope, settings: settings)

        var services = Self.group(controls, pluginSkills: skillsByKey)
        services = addMissingHarnesses(services, scope: scope)
        if scope == .allProjects { fillProjectCounts(&services) }

        var inventory = Inventory()
        inventory.services = services
        inventory.skills = skills
        for (harness, list) in byHarness {
            inventory.toolCounts[harness] = ToolCounts(controls: list, skills: harness == .claude ? skills.count : 0)
        }
        let overrides = settings.user["skillOverrides"] as? [String: String] ?? [:]
        inventory.deadOverrideKeys = showsClaude ? overrides.keys.filter { $0.contains(":") }.sorted() : []
        inventory.needsMigration = showsClaude && !settings.hasUserAllowlist
        return inventory
    }

    // MARK: Claude Code

    private struct ClaudeSource {
        let name: String
        let definition: ServerDefinition
        let label: String
        let kind: String
        var plugin: (id: String, name: String)?
        var isConnector = false
        var status: String?
        /// Known from history, but not on the account's current list.
        var notConnected = false
    }

    struct InstalledPluginInfo {
        let id: String
        let name: String
        let installPath: URL
    }

    func installedPlugins() -> [InstalledPluginInfo] {
        guard let json = try? readJSONObject(paths.installedPlugins),
              let map = json["plugins"] as? [String: [[String: Any]]] else { return [] }
        return map.compactMap { id, entries in
            guard let entry = entries.first else { return nil }
            let name = String(id.split(separator: "@", maxSplits: 1).first ?? Substring(id))
            return InstalledPluginInfo(
                id: id, name: name,
                installPath: URL(fileURLWithPath: entry["installPath"] as? String ?? "")
            )
        }.sorted { $0.id < $1.id }
    }

    /// A plugin's `.mcp.json` is either `{mcpServers: {…}}` or the servers directly.
    func pluginServers(_ plugin: InstalledPluginInfo) -> [String: ServerDefinition] {
        guard let json = try? readJSONObject(plugin.installPath.appendingPathComponent(".mcp.json")) else { return [:] }
        let servers = json["mcpServers"] as? [String: [String: Any]]
            ?? json.compactMapValues { $0 as? [String: Any] }
        return servers.mapValues { raw in
            var definition = ServerDefinition(json: raw)
            let root = "${CLAUDE_PLUGIN_ROOT}"
            definition.command = definition.command?.replacingOccurrences(of: root, with: plugin.installPath.path)
            definition.args = definition.args.map { $0.replacingOccurrences(of: root, with: plugin.installPath.path) }
            return definition
        }
    }

    private func connectorSources() -> [ClaudeSource] {
        var names = Set(state.connectors.keys)
        let claude = (try? readJSONObject(paths.claudeJson)) ?? [:]
        for name in claude["claudeAiMcpEverConnected"] as? [String] ?? [] { names.insert(name) }
        if let settings = try? readJSONObject(paths.claudeSettings) {
            for entry in settings["deniedMcpServers"] as? [[String: Any]] ?? [] {
                if let name = entry["serverName"] as? String, name.hasPrefix("claude.ai ") { names.insert(name) }
            }
        }
        for project in claude["projects"] as? [String: [String: Any]] ?? [:] {
            for name in project.value["disabledMcpServers"] as? [String] ?? [] where name.hasPrefix("claude.ai ") {
                names.insert(name)
            }
        }
        return names.filter { $0.hasPrefix("claude.ai ") }.sorted().map { name in
            let short = String(name.dropFirst("claude.ai ".count))
            let url = state.connectors[name] ?? Self.knownConnectorUrls[short]
            // Discovery gives every live connector a status and a URL. With no status
            // after a discovery, or no URL ever, it can't be running.
            let discovered = !state.connectorStatus.isEmpty
            let live = state.connectorStatus[name] != nil
            let notConnected = url == nil || (discovered && !live)
            return ClaudeSource(
                name: name,
                definition: ServerDefinition(url: url, portable: false),
                label: "claude.ai connector",
                kind: "claude.ai",
                isConnector: true,
                status: notConnected ? "Not connected" : state.connectorStatus[name],
                notConnected: notConnected
            )
        }
    }

    private func standaloneSources(scope: Scope, claude: [String: Any]) -> [ClaudeSource] {
        var sources: [ClaudeSource] = []
        for (name, raw) in claude["mcpServers"] as? [String: [String: Any]] ?? [:] {
            sources.append(ClaudeSource(name: name, definition: ServerDefinition(json: raw), label: "Your MCP server", kind: "MCP"))
        }
        guard let project = scope.projectPath else { return sources }
        let entry = (claude["projects"] as? [String: [String: Any]])?[project] ?? [:]
        for (name, raw) in entry["mcpServers"] as? [String: [String: Any]] ?? [:] {
            sources.append(ClaudeSource(name: name, definition: ServerDefinition(json: raw), label: "Added to this project", kind: "MCP"))
        }
        if let json = try? readJSONObject(paths.projectMcp(project)) {
            for (name, raw) in json["mcpServers"] as? [String: [String: Any]] ?? [:] {
                sources.append(ClaudeSource(name: name, definition: ServerDefinition(json: raw), label: "This repo's .mcp.json", kind: "MCP"))
            }
        }
        return sources
    }

    private static func allowRule(for source: ClaudeSource) -> ClaudeRule? {
        if let url = source.definition.url { return .url(ClaudeRule.urlPattern(url)) }
        if source.isConnector { return nil }
        if source.plugin != nil, let command = source.definition.commandLine { return .command(command) }
        return .name(source.name)
    }

    /// Sources sharing an allow rule are one server to Claude Code: the rule hits them all.
    private func serverRefs(from sources: [ClaudeSource]) -> [(ref: ClaudeServerRef, sources: [ClaudeSource])] {
        var order: [String] = []
        var grouped: [String: (ref: ClaudeServerRef, sources: [ClaudeSource])] = [:]
        for source in sources {
            let rule = Self.allowRule(for: source)
            let key: String
            switch rule {
            case .url(let value)?: key = "url:\(value)"
            case .command(let value)?: key = "cmd:\(value.joined(separator: " "))"
            case .name(let value)?: key = "name:\(value)"
            case nil: key = "name:\(source.name)"
            }
            let displayName = source.plugin.map { "plugin:\($0.name):\(source.name)" } ?? source.name
            var entry = grouped[key] ?? {
                order.append(key)
                let denyRule: ClaudeRule = rule ?? .name(source.name)
                return (ClaudeServerRef(
                    names: [], urls: [], command: source.definition.commandLine,
                    allowableNames: [], allowRule: rule, denyRule: denyRule
                ), [])
            }()
            entry.ref.names.insert(displayName)
            if let url = source.definition.url { entry.ref.urls.insert(url) }
            if !source.isConnector && source.plugin == nil {
                entry.ref.allowableNames.insert(source.name)
                entry.ref.hasStandaloneSource = true
            }
            if source.isConnector { entry.ref.hasStandaloneSource = true }
            if let plugin = source.plugin { entry.ref.ownerPlugins.insert(plugin.id) }
            entry.sources.append(source)
            grouped[key] = entry
        }
        return order.compactMap { grouped[$0] }
    }

    private func claudeControls(
        scope: Scope,
        settings: ClaudeSettings,
        pluginSkills: inout [String: [PluginSkillInfo]]
    ) throws -> [Control] {
        let claude = try readJSONObject(paths.claudeJson)
        var controls: [Control] = []
        var sources = standaloneSources(scope: scope, claude: claude) + connectorSources()

        for plugin in installedPlugins() {
            let enabled = settings.pluginEnabled(plugin.id)
            let skills = skillFolders(in: plugin.installPath.appendingPathComponent("skills")).map { folder -> PluginSkillInfo in
                let front = SkillFrontmatter(file: folder.appendingPathComponent("SKILL.md"))
                return PluginSkillInfo(
                    key: "\(plugin.name):\(folder.lastPathComponent)",
                    name: folder.lastPathComponent,
                    tokens: front.disablesModelInvocation ? 0 : front.tokens,
                    enabled: enabled
                )
            }.sorted { $0.name < $1.name }
            pluginSkills[normalize(plugin.name)] = skills

            let noun = skills.count == 1 ? "skill" : "skills"
            controls.append(Control(
                id: "claude.plugin.\(plugin.id)",
                harness: .claude,
                label: skills.isEmpty ? "Plugin" : "Plugin, \(skills.count) \(noun)",
                target: .claudePlugin(plugin.id),
                on: enabled,
                setUp: true,
                setHere: scope != .allProjects && settings.pluginSetLocally(plugin.id),
                lock: nil,
                groupKeys: ["name:\(normalize(plugin.name))"],
                kind: "Plugin"
            ))
            for (name, definition) in pluginServers(plugin).sorted(by: { $0.key < $1.key }) {
                sources.append(ClaudeSource(
                    name: name,
                    definition: definition,
                    label: "From the plugin",
                    kind: "MCP",
                    plugin: (plugin.id, plugin.name)
                ))
            }
        }

        for (ref, group) in serverRefs(from: sources) {
            let labels = uniqued(group.map(\.label))
            let primary = group.first { !$0.isConnector } ?? group[0]
            var keys = Set<String>()
            for source in group {
                if let plugin = source.plugin {
                    keys.insert("name:\(normalize(plugin.name))")
                } else {
                    keys.insert("name:\(normalize(source.name))")
                }
                if let host = source.definition.host, !isLocal(host) { keys.insert("host:\(host)") }
            }
            let onlyPlugin = !ref.hasStandaloneSource
            let pluginOn = ref.ownerPlugins.contains { settings.pluginEnabled($0) }
            let notConnected = group.allSatisfy(\.notConnected)
            let setHere: Bool
            if scope == .allProjects {
                setHere = false
            } else {
                setHere = settings.deniedHere(ref) || settings.allowedHere(ref) || settings.slashDisabledHere(ref)
            }
            controls.append(Control(
                id: "claude.server.\(group[0].name).\(ref.denyRule)",
                harness: .claude,
                label: labels.joined(separator: ", "),
                target: .claudeServer(ref),
                on: settings.isOn(ref) && (!onlyPlugin || pluginOn) && !notConnected,
                setUp: true,
                setHere: setHere,
                lock: notConnected
                    ? ControlLock(reason: "Not connected on claude.ai right now. Connect it there first.")
                    : claudeLock(ref, scope: scope, settings: settings),
                status: group.filter { !$0.notConnected }.compactMap(\.status).first ?? (notConnected ? "Not connected" : nil),
                groupKeys: keys,
                definition: primary.definition,
                kind: group.contains(where: { $0.kind == "MCP" }) ? "MCP" : group[0].kind
            ))
        }
        return controls
    }

    private func claudeLock(_ ref: ClaudeServerRef, scope: Scope, settings: ClaudeSettings) -> ControlLock? {
        if settings.deniedByShared(ref) {
            return ControlLock(reason: "Blocked by this repo's .claude/settings.json. Edit that file to change it.")
        }
        if scope != .allProjects && settings.deniedByUser(ref) {
            return ControlLock(
                reason: "Blocked in every project by your global list, and a project can't undo that. Switch to per-project control first.",
                fix: .switchToPerProject
            )
        }
        return nil
    }

    // MARK: Codex

    private func codexDefinition(_ doc: TOMLDocument, name: String) -> ServerDefinition? {
        let path = ["mcp_servers", name]
        guard doc.section(path) != nil else { return nil }
        let url = doc.string(path, "url")
        let command = doc.string(path, "command")
        guard url != nil || command != nil else { return nil }
        let args = doc.stringArray(path, "args") ?? []
        let hasSecrets = doc.section(path + ["env"]) != nil || doc.section(path + ["http_headers"]) != nil
            || doc.raw(path, "env") != nil || doc.raw(path, "http_headers") != nil
            || doc.raw(path, "bearer_token_env_var") != nil
        return ServerDefinition(
            url: url, command: command, args: args,
            portable: !hasSecrets && ServerDefinition.argsArePortable(args, url: url)
        )
    }

    private func codexLock(scope: Scope, global: TOMLDocument) -> ControlLock? {
        guard let path = scope.projectPath, global.string(["projects", path], "trust_level") != "trusted" else { return nil }
        return ControlLock(reason: "Codex ignores this project's settings until you trust the folder.", fix: .trustCodex)
    }

    private func codexControls(scope: Scope) -> [Control] {
        let global = TOMLDocument((try? String(contentsOf: paths.codexConfig, encoding: .utf8)) ?? "")
        let project = scope.projectPath.map {
            TOMLDocument((try? String(contentsOf: paths.codexProject($0), encoding: .utf8)) ?? "")
        }
        let lock = codexLock(scope: scope, global: global)

        func enabled(_ path: [String]) -> Bool {
            project?.bool(path, "enabled") ?? global.bool(path, "enabled") ?? true
        }
        func setHere(_ path: [String]) -> Bool {
            project?.bool(path, "enabled") != nil
        }

        var controls: [Control] = []
        var names = global.children(of: "mcp_servers")
        for name in project?.children(of: "mcp_servers") ?? [] where !names.contains(name) { names.append(name) }
        for name in names {
            let path = ["mcp_servers", name]
            let globalDefinition = codexDefinition(global, name: name)
            let definition = project.flatMap { codexDefinition($0, name: name) } ?? globalDefinition
            var keys: Set<String> = ["name:\(normalize(name))"]
            if let host = definition?.host, !isLocal(host) { keys.insert("host:\(host)") }
            controls.append(Control(
                id: "codex.server.\(name)",
                harness: .codex,
                label: "MCP server",
                target: .codexServer(name: name, definition: definition, definedGlobally: globalDefinition != nil),
                on: enabled(path),
                setUp: true,
                setHere: setHere(path),
                lock: lock,
                groupKeys: keys,
                definition: definition
            ))
        }
        for id in global.children(of: "plugins") {
            let name = String(id.split(separator: "@", maxSplits: 1).first ?? Substring(id))
            let path = ["plugins", id]
            controls.append(Control(
                id: "codex.plugin.\(id)",
                harness: .codex,
                label: "Plugin",
                target: .codexPlugin(id),
                on: enabled(path),
                setUp: true,
                setHere: setHere(path),
                lock: lock,
                groupKeys: ["name:\(normalize(name))"],
                kind: "Plugin"
            ))
        }
        for id in global.children(of: "apps") where id != "_default" {
            let path = ["apps", id]
            let short = id.replacingOccurrences(of: "connector_", with: "").prefix(8)
            controls.append(Control(
                id: "codex.app.\(id)",
                harness: .codex,
                label: "ChatGPT connector",
                target: .codexApp(id),
                on: enabled(path),
                setUp: true,
                setHere: setHere(path),
                lock: lock,
                groupKeys: ["name:codex connector \(short)"],
                kind: "Connector"
            ))
        }
        return controls
    }

    // MARK: Antigravity

    private func antigravityControls(scope: Scope) -> [Control] {
        let global = (try? readJSONObject(paths.antigravityConfig))?["mcpServers"] as? [String: [String: Any]] ?? [:]
        var controls: [Control] = []
        func keys(_ name: String, _ definition: ServerDefinition) -> Set<String> {
            var result: Set<String> = ["name:\(normalize(name))"]
            if let host = definition.host, !isLocal(host) { result.insert("host:\(host)") }
            return result
        }

        guard let project = scope.projectPath else {
            for (name, raw) in global.sorted(by: { $0.key < $1.key }) {
                let definition = ServerDefinition(json: raw)
                controls.append(Control(
                    id: "antigravity.server.\(name)",
                    harness: .antigravity,
                    label: "MCP server",
                    target: .antigravityServer(name: name, definition: definition, definedGlobally: true),
                    on: raw["disabled"] as? Bool != true,
                    setUp: true,
                    setHere: false,
                    lock: nil,
                    groupKeys: keys(name, definition),
                    definition: definition
                ))
            }
            return controls
        }

        let workspace = (try? readJSONObject(paths.antigravityWorkspace(project)))?["mcpServers"] as? [String: [String: Any]] ?? [:]
        let parked = state.antigravityOff[project] ?? [:]
        for name in Set(global.keys).union(workspace.keys).union(parked.keys).sorted() {
            let raw = workspace[name] ?? global[name]
            let definition = raw.map { ServerDefinition(json: $0) } ?? parked[name]?.definition ?? ServerDefinition()
            var lock: ControlLock?
            if let entry = global[name], workspace[name] == nil, entry["disabled"] as? Bool != true {
                lock = ControlLock(reason: "On in every project from Antigravity's global config, and it has no working per-project off. Turn it off under All projects.")
            } else if workspace[name] != nil && !definition.portable {
                lock = ControlLock(reason: "Holds private settings. Edit .agents/mcp_config.json by hand.")
            }
            controls.append(Control(
                id: "antigravity.server.\(name)",
                harness: .antigravity,
                label: "MCP server",
                target: .antigravityServer(name: name, definition: definition, definedGlobally: global[name] != nil),
                on: workspace[name] != nil || (global[name].map { $0["disabled"] as? Bool != true } ?? false),
                setUp: true,
                setHere: workspace[name] != nil || parked[name] != nil,
                lock: lock,
                groupKeys: keys(name, definition),
                definition: definition
            ))
        }
        return controls
    }

    // MARK: Cursor

    private func cursorControls(scope: Scope) -> [Control] {
        var servers = (try? readJSONObject(paths.cursorConfig))?["mcpServers"] as? [String: [String: Any]] ?? [:]
        if let project = scope.projectPath,
           let own = (try? readJSONObject(paths.cursorProject(project)))?["mcpServers"] as? [String: [String: Any]] {
            servers.merge(own) { _, new in new }
        }
        return servers.sorted(by: { $0.key < $1.key }).map { name, raw in
            let definition = ServerDefinition(json: raw)
            var keys: Set<String> = ["name:\(normalize(name))"]
            if let host = definition.host, !isLocal(host) { keys.insert("host:\(host)") }
            return Control(
                id: "cursor.server.\(name)",
                harness: .cursor,
                label: "MCP server",
                target: .cursorServer(name),
                on: true,
                setUp: true,
                setHere: false,
                lock: ControlLock(reason: "Cursor keeps this in its own app state. Change it in Cursor Settings."),
                groupKeys: keys,
                definition: definition
            )
        }
    }

    // MARK: Grouping

    /// Merges controls that share a name or URL host into one service.
    static func group(_ controls: [Control], pluginSkills: [String: [PluginSkillInfo]]) -> [Service] {
        var parent = Array(controls.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        // `figma-developer` joins `figma`, but only when a service called exactly `figma`
        // exists. So `google-drive` and `google-calendar` never merge on their own.
        let exactNames = Set(controls.flatMap(\.groupKeys).filter { $0.hasPrefix("name:") })
        func keys(_ control: Control) -> Set<String> {
            var keys = control.groupKeys
            for key in control.groupKeys where key.hasPrefix("name:") {
                let token = key.dropFirst(5).prefix { $0 != "-" && $0 != "_" && $0 != " " }
                if exactNames.contains("name:\(token)") { keys.insert("name:\(token)") }
            }
            return keys
        }
        var firstWithKey: [String: Int] = [:]
        for (index, control) in controls.enumerated() {
            for key in keys(control) {
                if let other = firstWithKey[key] {
                    parent[find(index)] = find(other)
                } else {
                    firstWithKey[key] = index
                }
            }
        }
        var groups: [Int: [Control]] = [:]
        for index in controls.indices { groups[find(index), default: []].append(controls[index]) }

        return groups.values.map { members -> Service in
            let name = displayName(for: members)
            var skills: [PluginSkillInfo] = []
            for key in Set(members.flatMap(\.groupKeys)) where key.hasPrefix("name:") {
                skills += pluginSkills[String(key.dropFirst(5))] ?? []
            }
            let ordered = members.sorted {
                let a = Harness.allCases.firstIndex(of: $0.harness) ?? 0
                let b = Harness.allCases.firstIndex(of: $1.harness) ?? 0
                if a != b { return a < b }
                return kindRank($0.kind) < kindRank($1.kind)
            }
            return Service(
                id: name.lowercased(),
                name: name,
                controls: ordered,
                pluginSkills: skills.sorted { $0.name < $1.name }
            )
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func kindRank(_ kind: String) -> Int {
        ["Plugin", "MCP", "claude.ai", "Connector"].firstIndex(of: kind) ?? 9
    }

    /// A connector's display name is the nicest we have. Otherwise tidy a config name.
    private static func displayName(for members: [Control]) -> String {
        for member in members {
            if case .claudeServer(let ref) = member.target,
               let connector = ref.names.sorted().first(where: { $0.hasPrefix("claude.ai ") }) {
                return String(connector.dropFirst("claude.ai ".count))
            }
        }
        let names = members.flatMap(\.groupKeys).filter { $0.hasPrefix("name:") }.map { String($0.dropFirst(5)) }
            .sorted { ($0.count, $0) < ($1.count, $1) }
        return titleCase(names.first ?? "Unknown")
    }

    private static func titleCase(_ raw: String) -> String {
        raw.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// In a project, offers to add a service to a tool that doesn't have it, when a
    /// definition exists that's safe to copy.
    private func addMissingHarnesses(_ services: [Service], scope: Scope) -> [Service] {
        guard scope != .allProjects else { return services }
        let codexConfig = TOMLDocument((try? String(contentsOf: paths.codexConfig, encoding: .utf8)) ?? "")
        let trustLock = codexLock(scope: scope, global: codexConfig)
        return services.map { service in
            guard let definition = service.active.compactMap(\.definition).first(where: { $0.portable && ($0.url != nil || $0.command != nil) })
            else { return service }
            var service = service
            let serverName = service.id.replacingOccurrences(of: " ", with: "-")
            for harness in [Harness.codex, .antigravity] where state.manages(harness, paths: paths) {
                guard !service.controls.contains(where: {
                    if $0.harness != harness { return false }
                    if case .codexServer = $0.target { return true }
                    if case .antigravityServer = $0.target { return true }
                    return false
                }) else { continue }
                let target: ControlTarget = harness == .codex
                    ? .codexServer(name: serverName, definition: definition, definedGlobally: false)
                    : .antigravityServer(name: serverName, definition: definition, definedGlobally: false)
                service.controls.append(Control(
                    id: "\(harness.rawValue).add.\(serverName)",
                    harness: harness,
                    label: "Not set up",
                    target: target,
                    on: false,
                    setUp: false,
                    setHere: false,
                    lock: harness == .codex ? trustLock : nil,
                    definition: definition
                ))
            }
            return service
        }
    }

    // MARK: Project counts

    private func fillProjectCounts(_ services: inout [Service]) {
        guard let claude = try? readJSONObject(paths.claudeJson),
              let projects = claude["projects"] as? [String: [String: Any]] else { return }
        let user = (try? readJSONObject(paths.claudeSettings)) ?? [:]
        let known = projects.sorted { $0.key < $1.key }.prefix(Self.projectScanLimit)
        let scanned: [(folder: String, settings: ClaudeSettings)] = known.compactMap { path, entry in
            let local = isHome(path) ? [:] : ((try? readJSONObject(paths.claudeLocal(path))) ?? [:])
            let shared = isHome(path) ? [:] : ((try? readJSONObject(paths.claudeShared(path))) ?? [:])
            let disabled = entry["disabledMcpServers"] as? [String] ?? []
            guard !local.isEmpty || !shared.isEmpty || !disabled.isEmpty else { return nil }
            return (
                (path as NSString).lastPathComponent,
                ClaudeSettings(user: user, shared: shared, local: local, projectEntry: entry)
            )
        }
        for index in services.indices {
            var folders: [String] = []
            for project in scanned {
                let matched = services[index].controls.contains { control in
                    switch control.target {
                    case .claudePlugin(let id):
                        return project.settings.pluginSetHere(id)
                    case .claudeServer(let ref):
                        return project.settings.deniedHere(ref) || project.settings.deniedByShared(ref)
                            || project.settings.allowedHere(ref) || project.settings.slashDisabledHere(ref)
                    default:
                        return false
                    }
                }
                if matched { folders.append(project.folder) }
            }
            services[index].setInProjects = folders
        }
    }

    // MARK: Skills

    private func overrides(_ file: [String: Any]) -> [String: SkillOverride] {
        (file["skillOverrides"] as? [String: String] ?? [:]).compactMapValues { SkillOverride(rawValue: $0) }
    }

    /// Resolves local > project > user. A skill that opts out of model use stays Manual
    /// unless it's off.
    static func effective(stored: SkillOverride, lock: SkillLock?) -> SkillOverride {
        guard lock == .author else { return stored }
        return stored == .off ? .off : .userInvocableOnly
    }

    private func loadSkills(scope: Scope, settings: ClaudeSettings) -> [SkillItem] {
        let user = overrides(settings.user)
        let shared = overrides(settings.shared)
        let local = overrides(settings.local)
        var folders: [(URL, SkillSource)] = skillFolders(in: paths.userSkills).map { ($0, .user) }
        if let project = scope.projectPath {
            folders += skillFolders(in: paths.projectSkills(project)).map { ($0, .project) }
        }

        var items = folders.map { folder, source -> SkillItem in
            let key = folder.lastPathComponent
            let front = SkillFrontmatter(file: folder.appendingPathComponent("SKILL.md"))
            let lock: SkillLock? = front.disablesModelInvocation ? .author : nil
            let stored = local[key] ?? shared[key] ?? user[key] ?? .on
            return SkillItem(
                key: key,
                source: source,
                folder: folder,
                tokens: front.disablesModelInvocation ? 0 : front.tokens,
                lock: lock,
                state: Self.effective(stored: stored, lock: lock),
                setHere: local[key] != nil
            )
        }
        .sorted { $0.key.lowercased() < $1.key.lowercased() }

        if scope == .allProjects { fillSkillProjects(&items, user: user) }
        return items
    }

    private func fillSkillProjects(_ items: inout [SkillItem], user: [String: SkillOverride]) {
        guard let claude = try? readJSONObject(paths.claudeJson),
              let projects = claude["projects"] as? [String: Any] else { return }
        var result: [String: [ProjectOverride]] = [:]
        for path in projects.keys.sorted().prefix(Self.projectScanLimit) where !isHome(path) {
            let shared = overrides((try? readJSONObject(paths.claudeShared(path))) ?? [:])
            let local = overrides((try? readJSONObject(paths.claudeLocal(path))) ?? [:])
            guard !shared.isEmpty || !local.isEmpty else { continue }
            let folder = (path as NSString).lastPathComponent
            for item in items {
                guard let state = local[item.key] ?? shared[item.key],
                      state != (user[item.key] ?? .on) else { continue }
                result[item.key, default: []].append(ProjectOverride(project: folder, state: state))
            }
        }
        for index in items.indices { items[index].projects = result[items[index].key] ?? [] }
    }
}

// MARK: - Helpers

func normalize(_ name: String) -> String {
    var value = name.lowercased()
    if value.hasPrefix("claude.ai ") { value.removeFirst("claude.ai ".count) }
    value = value.trimmingCharacters(in: .whitespaces)
    for suffix in ["-mcp", "_mcp", " mcp"] where value.hasSuffix(suffix) {
        value.removeLast(suffix.count)
    }
    return value
}

func isLocal(_ host: String) -> Bool {
    host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1") || host.hasPrefix("[::1]")
}

func uniqued<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    return values.filter { seen.insert($0).inserted }
}
