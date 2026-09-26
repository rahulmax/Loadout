import SwiftUI
import AppKit

@main
struct LoadoutApp: App {
    @StateObject private var store = AppStore()

    init() {
        #if DEBUG
        SnapshotRenderer.runIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            Image(nsImage: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    /// Backpack template image from Resources/ (copied into the bundle by build.sh).
    /// Falls back to an SF Symbol when run outside the .app bundle (e.g. `swift run`).
    private var menuBarIcon: NSImage {
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "backpack", accessibilityDescription: "Loadout")
            ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}

// MARK: - Models

struct InstalledPlugin: Identifiable, Hashable {
    var id: String { fullId }
    let fullId: String
    let name: String
    let marketplace: String
    let version: String
    let installPath: String
    var enabled: Bool
}

enum SkillOverride: String, CaseIterable, Identifiable {
    case on
    case nameOnly = "name-only"
    case userInvocableOnly = "user-invocable-only"
    case off

    var id: String { rawValue }
    var label: String {
        switch self {
        case .on: return "On"
        case .nameOnly: return "Name only"
        case .userInvocableOnly: return "Slash only"
        case .off: return "Off"
        }
    }
    var symbol: String {
        switch self {
        case .on: return "checkmark.circle.fill"
        case .nameOnly: return "text.alignleft"
        case .userInvocableOnly: return "slash.circle"
        case .off: return "xmark.circle"
        }
    }
}

/// Why a skill's state can't be set from user settings. Mirrors Claude Code's `locked_by`.
enum SkillLock: Hashable {
    /// Plugin skills ignore `skillOverrides`; only the plugin switch drops them.
    case plugin
    /// The skill sets `disable-model-invocation`, so it is slash-only unless turned off.
    case author
}

struct DiscoveredSkill: Identifiable, Hashable {
    var id: String { key }
    let key: String              // "compose" or "impeccable:polish"
    let displayName: String
    let source: String           // "user" or plugin name
    let pluginEnabled: Bool       // if false, the skill is dormant regardless of override
    let lock: SkillLock?
}

/// A project whose own settings give a skill a different state than the global one.
struct ProjectOverride: Hashable {
    let project: String          // folder name
    let state: SkillOverride
}

struct LocalMCPServer: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let kind: String              // stdio, http, sse
    let summary: String           // command or url, truncated
    var enabled: Bool
    var offInProjects: [String] = []
}

struct ClaudeAiIntegration: Identifiable, Hashable {
    var id: String { name }
    let name: String              // "Gmail", "Slack", "Google Drive", etc.
    let url: String
    let status: String            // "Connected", "Needs authentication", etc.
    var denied: Bool
    var offInProjects: [String] = []
}

// MARK: - Store

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var plugins: [InstalledPlugin] = []
    @Published private(set) var skills: [DiscoveredSkill] = []
    @Published private(set) var skillOverrides: [String: SkillOverride] = [:]
    /// `plugin:skill` keys in `skillOverrides`. Claude Code never reads them.
    @Published private(set) var deadOverrideKeys: [String] = []
    /// User skill key → projects whose own settings give it a different state.
    @Published private(set) var skillProjectOverrides: [String: [ProjectOverride]] = [:]
    @Published private(set) var mcpServers: [LocalMCPServer] = []
    /// Server name → folders where `/mcp` turned it off for that project only.
    @Published private(set) var mcpProjectDisables: [String: [String]] = [:]
    @Published private(set) var claudeAiIntegrations: [ClaudeAiIntegration] = []
    @Published private(set) var loadingClaudeAi: Bool = false
    @Published private(set) var lastError: String?
    /// True for a few seconds after a toggle copies `/reload-plugins`; drives the footer confirmation.
    @Published private(set) var justCopied = false
    private var copiedResetTask: Task<Void, Never>?

    private let home: URL
    /// Set for snapshot runs: every write throws, so rendering can never touch real config.
    private let readOnly: Bool
    private var installedUrl: URL { home.appendingPathComponent(".claude/plugins/installed_plugins.json") }
    private var settingsUrl: URL { home.appendingPathComponent(".claude/settings.json") }
    private var claudeJsonUrl: URL { home.appendingPathComponent(".claude.json") }
    private var userSkillsDir: URL { home.appendingPathComponent(".claude/skills") }

    /// Projects whose settings are read per reload, to flag overrides. Keeps a huge
    /// `~/.claude.json` history from slowing the panel down.
    private static let projectScanLimit = 200

    init(home: URL = AppStore.defaultHome, readOnly: Bool = AppStore.isSnapshotRun) {
        self.home = home
        self.readOnly = readOnly
        migrateParkedServers()
        reload()
    }

    /// Debug builds can point the store at a fixture folder with `LOADOUT_HOME`.
    nonisolated static var defaultHome: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["LOADOUT_HOME"] {
            return URL(fileURLWithPath: path)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }

    nonisolated static var isSnapshotRun: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LOADOUT_SNAPSHOT"] != nil
        #else
        return false
        #endif
    }

    func reload() {
        do {
            try loadPlugins()
            try loadSkills()
            try loadMCPs()
            applyDenyStateToClaudeAi()
            lastError = nil
        } catch {
            lastError = "Read failed: \(error.localizedDescription)"
        }
        Task { await loadClaudeAiInventory() }
    }

    // MARK: Plugins

    private func loadPlugins() throws {
        let installedJson = try readJSON(installedUrl)
        let pluginsMap = installedJson["plugins"] as? [String: [[String: Any]]] ?? [:]
        let settingsJson = try readJSON(settingsUrl)
        let enabledMap = settingsJson["enabledPlugins"] as? [String: Bool] ?? [:]

        plugins = pluginsMap.compactMap { (fullId, entries) -> InstalledPlugin? in
            guard let entry = entries.first else { return nil }
            let parts = fullId.split(separator: "@", maxSplits: 1)
            return InstalledPlugin(
                fullId: fullId,
                name: String(parts.first ?? Substring(fullId)),
                marketplace: parts.count > 1 ? String(parts[1]) : "",
                version: entry["version"] as? String ?? "unknown",
                installPath: entry["installPath"] as? String ?? "",
                enabled: enabledMap[fullId] ?? true
            )
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func togglePlugin(_ plugin: InstalledPlugin) {
        let newValue = !plugin.enabled
        do {
            try writeSettings { json in
                var map = json["enabledPlugins"] as? [String: Bool] ?? [:]
                map[plugin.fullId] = newValue
                json["enabledPlugins"] = map
            }
            markToggled()
            reload()
        } catch {
            lastError = "Could not toggle plugin: \(error.localizedDescription)"
        }
    }

    // MARK: Skills

    private func loadSkills() throws {
        let settings = try readJSON(settingsUrl)
        let overrides = settings["skillOverrides"] as? [String: String] ?? [:]
        skillOverrides = overrides.compactMapValues { SkillOverride(rawValue: $0) }
        deadOverrideKeys = overrides.keys.filter { $0.contains(":") }.sorted()

        var found: [DiscoveredSkill] = []

        // user-level
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: userSkillsDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for url in entries {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir,
                      FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path)
                else { continue }
                // Claude Code keys user skills by folder name, not the frontmatter `name`.
                let name = url.lastPathComponent
                let skillFile = url.appendingPathComponent("SKILL.md")
                found.append(DiscoveredSkill(
                    key: name,
                    displayName: name,
                    source: "user",
                    pluginEnabled: true,
                    lock: disablesModelInvocation(skillFile) ? .author : nil
                ))
            }
        }

        // plugin-bundled
        for plugin in plugins {
            let skillsDir = URL(fileURLWithPath: plugin.installPath).appendingPathComponent("skills")
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: skillsDir, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for url in entries {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir,
                      FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path)
                else { continue }
                let skillName = url.lastPathComponent
                let key = "\(plugin.name):\(skillName)"
                found.append(DiscoveredSkill(
                    key: key,
                    displayName: skillName,
                    source: plugin.name,
                    pluginEnabled: plugin.enabled,
                    lock: .plugin
                ))
            }
        }

        skills = found.sorted {
            ($0.source.lowercased(), $0.displayName.lowercased())
                < ($1.source.lowercased(), $1.displayName.lowercased())
        }
        skillProjectOverrides = loadSkillProjectOverrides(userSkills: found.filter { $0.lock != .plugin })
    }

    /// True when SKILL.md frontmatter sets `disable-model-invocation: true`.
    private func disablesModelInvocation(_ file: URL) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              text.hasPrefix("---") else { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces) == "disable-model-invocation" {
                return parts[1].trimmingCharacters(in: .whitespaces).lowercased() == "true"
            }
        }
        return false
    }

    /// Project folders Claude Code has opened, from `~/.claude.json`, by path.
    private func knownProjects(_ claudeJson: [String: Any]) -> [(path: String, config: [String: Any])] {
        let projects = claudeJson["projects"] as? [String: [String: Any]] ?? [:]
        return projects
            .sorted { $0.key < $1.key }
            .prefix(Self.projectScanLimit)
            .map { (path: $0.key, config: $0.value) }
    }

    /// For each user skill, the projects whose settings.json or settings.local.json give it
    /// a state other than the global one. Claude Code applies local > project > user.
    private func loadSkillProjectOverrides(userSkills: [DiscoveredSkill]) -> [String: [ProjectOverride]] {
        guard let claudeJson = try? readJSON(claudeJsonUrl) else { return [:] }
        var result: [String: [ProjectOverride]] = [:]
        for project in knownProjects(claudeJson) {
            let dir = URL(fileURLWithPath: project.path).appendingPathComponent(".claude")
            // In the home folder, .claude/settings.json is the user file itself.
            let isHome = URL(fileURLWithPath: project.path).standardizedFileURL == home.standardizedFileURL
            let shared = isHome ? [:] : projectSkillOverrides(dir.appendingPathComponent("settings.json"))
            let local = projectSkillOverrides(dir.appendingPathComponent("settings.local.json"))
            guard !shared.isEmpty || !local.isEmpty else { continue }
            let folder = URL(fileURLWithPath: project.path).lastPathComponent
            for skill in userSkills {
                guard let state = local[skill.key] ?? shared[skill.key],
                      state != (skillOverrides[skill.key] ?? .on) else { continue }
                result[skill.key, default: []].append(ProjectOverride(project: folder, state: state))
            }
        }
        return result
    }

    private func projectSkillOverrides(_ url: URL) -> [String: SkillOverride] {
        guard FileManager.default.fileExists(atPath: url.path),
              let json = try? readJSON(url),
              let map = json["skillOverrides"] as? [String: String] else { return [:] }
        return map.compactMapValues { SkillOverride(rawValue: $0) }
    }

    /// The state Claude Code resolves from user settings: author-locked skills are slash-only
    /// unless turned off. Plugin skills are always on while their plugin is.
    func effectiveState(_ skill: DiscoveredSkill) -> SkillOverride {
        let stored = skillOverrides[skill.key] ?? .on
        switch skill.lock {
        case .plugin: return .on
        case .author: return stored == .off ? .off : .userInvocableOnly
        case nil: return stored
        }
    }

    func setSkillOverride(_ skill: DiscoveredSkill, to value: SkillOverride) {
        guard skill.lock != .plugin else { return }
        // An author-locked skill is already slash-only; the only real choice is Off.
        let value: SkillOverride = skill.lock == .author && value != .off ? .on : value
        do {
            try writeSettings { json in
                var map = json["skillOverrides"] as? [String: String] ?? [:]
                if value == .on {
                    map.removeValue(forKey: skill.key)
                } else {
                    map[skill.key] = value.rawValue
                }
                if map.isEmpty {
                    json.removeValue(forKey: "skillOverrides")
                } else {
                    json["skillOverrides"] = map
                }
            }
            markToggled()
            reload()
        } catch {
            lastError = "Could not update skill: \(error.localizedDescription)"
        }
    }

    /// Sets every user skill to `off` in a single settings write. Plugin skills are
    /// skipped: Claude Code ignores overrides for them.
    func turnOffAllSkills() {
        let targets = skills.filter { $0.lock != .plugin }
        guard !targets.isEmpty else { return }
        do {
            try writeSettings { json in
                var map = json["skillOverrides"] as? [String: String] ?? [:]
                for skill in targets {
                    map[skill.key] = SkillOverride.off.rawValue
                }
                json["skillOverrides"] = map
            }
            markToggled()
            reload()
        } catch {
            lastError = "Could not turn off skills: \(error.localizedDescription)"
        }
    }

    /// Removes the `plugin:skill` keys earlier versions wrote. They never had an effect.
    func removeDeadOverrides() {
        let dead = Set(deadOverrideKeys)
        guard !dead.isEmpty else { return }
        do {
            try writeSettings { json in
                var map = json["skillOverrides"] as? [String: String] ?? [:]
                map = map.filter { !dead.contains($0.key) }
                if map.isEmpty {
                    json.removeValue(forKey: "skillOverrides")
                } else {
                    json["skillOverrides"] = map
                }
            }
            reload()
        } catch {
            lastError = "Could not clean up overrides: \(error.localizedDescription)"
        }
    }

    // MARK: Local MCP servers

    /// A local server is off when `deniedMcpServers` names it. Its config stays in
    /// `mcpServers`, so Loadout never has to write `~/.claude.json` to toggle it.
    private func loadMCPs() throws {
        let claudeJson = try readJSON(claudeJsonUrl)
        let active = claudeJson["mcpServers"] as? [String: [String: Any]] ?? [:]
        // Parked by Loadout before 1.1; only still here in a read-only run.
        let parked = claudeJson["_disabledMcpServers"] as? [String: [String: Any]] ?? [:]
        let deniedNames = readDenyNames()

        var found: [LocalMCPServer] = []
        for (name, cfg) in active {
            found.append(makeServer(name: name, cfg: cfg, enabled: !deniedNames.contains(name)))
        }
        for (name, cfg) in parked where active[name] == nil {
            found.append(makeServer(name: name, cfg: cfg, enabled: false))
        }
        mcpProjectDisables = loadMcpProjectDisables(claudeJson)
        mcpServers = found
            .map { server in
                var server = server
                server.offInProjects = mcpProjectDisables[server.name] ?? []
                return server
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Server name → folders where `/mcp` turned it off (`projects[path].disabledMcpServers`).
    private func loadMcpProjectDisables(_ claudeJson: [String: Any]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for project in knownProjects(claudeJson) {
            let folder = URL(fileURLWithPath: project.path).lastPathComponent
            for name in project.config["disabledMcpServers"] as? [String] ?? [] {
                result[name, default: []].append(folder)
            }
        }
        return result
    }

    /// One-time move off the old `_disabledMcpServers` parking lot: deny each parked
    /// server by name first, then put its config back. If the second write fails the
    /// server is still blocked. Backs up `~/.claude.json` once before touching it.
    private func migrateParkedServers() {
        guard !readOnly,
              let claudeJson = try? readJSON(claudeJsonUrl),
              let parked = claudeJson["_disabledMcpServers"] as? [String: Any]
        else { return }
        do {
            let backup = home.appendingPathComponent(".claude.json.loadout-backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: claudeJsonUrl, to: backup)
            }
            if !parked.isEmpty {
                try updateDenyList { deny in
                    for name in parked.keys.sorted()
                    where !deny.contains(where: { ($0["serverName"] as? String) == name }) {
                        deny.append(["serverName": name])
                    }
                }
            }
            try writeClaudeJson { json in
                var active = json["mcpServers"] as? [String: Any] ?? [:]
                let stillParked = json["_disabledMcpServers"] as? [String: Any] ?? [:]
                for (name, cfg) in stillParked where active[name] == nil {
                    active[name] = cfg
                }
                json["mcpServers"] = active
                json.removeValue(forKey: "_disabledMcpServers")
            }
        } catch {
            lastError = "Could not migrate parked MCP servers: \(error.localizedDescription)"
        }
    }

    private func makeServer(name: String, cfg: [String: Any], enabled: Bool) -> LocalMCPServer {
        let kind = cfg["type"] as? String ?? "stdio"
        let summary: String
        if let url = cfg["url"] as? String {
            summary = url
        } else if let cmd = cfg["command"] as? String {
            let args = (cfg["args"] as? [String])?.joined(separator: " ") ?? ""
            summary = (cmd + " " + args).trimmingCharacters(in: .whitespaces)
        } else {
            summary = ""
        }
        return LocalMCPServer(name: name, kind: kind, summary: summary, enabled: enabled)
    }

    // MARK: claude.ai integrations

    static let claudeAiCatalog: [(name: String, url: String)] = [
        ("Gmail", "https://gmailmcp.googleapis.com/mcp/v1"),
        ("Google Calendar", "https://calendarmcp.googleapis.com/mcp/v1"),
        ("Google Drive", "https://drivemcp.googleapis.com/mcp/v1"),
        ("Slack", "https://mcp.slack.com/mcp"),
        ("Miro", "https://mcp.miro.com"),
        ("Figma", "https://mcp.figma.com/mcp"),
    ]

    func loadClaudeAiInventory() async {
        loadingClaudeAi = true
        let entries = await Task.detached { runClaudeMcpList() }.value
        let denyUrls = readDenyUrls()

        var statusByUrl: [String: String] = [:]
        for entry in entries where entry.name.hasPrefix("claude.ai ") {
            statusByUrl[entry.url] = entry.status
        }

        claudeAiIntegrations = AppStore.claudeAiCatalog.map { item in
            let denied = denyUrls.contains(item.url)
            let status: String
            if denied {
                status = "Blocked locally"
            } else if let s = statusByUrl[item.url] {
                status = s
            } else {
                status = "Not connected"
            }
            return ClaudeAiIntegration(
                name: item.name, url: item.url, status: status, denied: denied,
                offInProjects: mcpProjectDisables["claude.ai \(item.name)"] ?? []
            )
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
        loadingClaudeAi = false
    }

    private func applyDenyStateToClaudeAi() {
        let denyUrls = readDenyUrls()
        claudeAiIntegrations = claudeAiIntegrations.map { entry in
            var updated = entry
            updated.denied = denyUrls.contains(entry.url)
            updated.offInProjects = mcpProjectDisables["claude.ai \(entry.name)"] ?? []
            return updated
        }
    }

    // MARK: deniedMcpServers

    /// Entries take exactly one of `serverName`, `serverUrl` or `serverCommand`, matched
    /// verbatim. Loadout writes the first two and leaves any other entry alone.
    private func readDenyEntries() -> [[String: Any]] {
        guard let json = try? readJSON(settingsUrl) else { return [] }
        return json["deniedMcpServers"] as? [[String: Any]] ?? []
    }

    private func readDenyUrls() -> Set<String> {
        Set(readDenyEntries().compactMap { $0["serverUrl"] as? String })
    }

    private func readDenyNames() -> Set<String> {
        Set(readDenyEntries().compactMap { $0["serverName"] as? String })
    }

    private func updateDenyList(_ mutate: (inout [[String: Any]]) -> Void) throws {
        try writeSettings { json in
            var deny = json["deniedMcpServers"] as? [[String: Any]] ?? []
            mutate(&deny)
            if deny.isEmpty {
                json.removeValue(forKey: "deniedMcpServers")
            } else {
                json["deniedMcpServers"] = deny
            }
        }
    }

    func toggleClaudeAiIntegration(_ integration: ClaudeAiIntegration) {
        do {
            try updateDenyList { deny in
                if integration.denied {
                    deny.removeAll { ($0["serverUrl"] as? String) == integration.url }
                } else {
                    deny.append(["serverUrl": integration.url])
                }
            }
            markToggled()
            applyDenyStateToClaudeAi()
        } catch {
            lastError = "Could not toggle integration: \(error.localizedDescription)"
        }
    }

    func toggleMCPServer(_ server: LocalMCPServer) {
        do {
            try updateDenyList { deny in
                if server.enabled {
                    deny.append(["serverName": server.name])
                } else {
                    deny.removeAll { ($0["serverName"] as? String) == server.name }
                }
            }
            markToggled()
            reload()
        } catch {
            lastError = "Could not toggle MCP server: \(error.localizedDescription)"
        }
    }

    // MARK: Helpers

    private func markToggled() {
        copyReloadCommand()
        justCopied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { justCopied = false }
        }
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func writeSettings(_ mutate: (inout [String: Any]) -> Void) throws {
        try mutateJSON(at: settingsUrl, mutate: mutate)
    }

    private func writeClaudeJson(_ mutate: (inout [String: Any]) -> Void) throws {
        try mutateJSON(at: claudeJsonUrl, mutate: mutate)
    }

    private func mutateJSON(at url: URL, mutate: (inout [String: Any]) -> Void) throws {
        guard !readOnly else {
            throw NSError(domain: "Loadout", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Read-only run: not writing \(url.lastPathComponent)"])
        }
        let data = try Data(contentsOf: url)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Loadout", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Not a JSON object: \(url.lastPathComponent)"])
        }
        mutate(&json)
        let newData = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        let tmp = url.appendingPathExtension("tmp")
        try newData.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

func copyReloadCommand() {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString("/reload-plugins", forType: .string)
}

struct ParsedMcpEntry {
    let name: String
    let url: String
    let status: String
}

func runClaudeMcpList() -> [ParsedMcpEntry] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "claude mcp list"]
    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = Pipe()
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        return []
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""
    return parseMcpList(text)
}

func parseMcpList(_ text: String) -> [ParsedMcpEntry] {
    var result: [ParsedMcpEntry] = []
    for rawLine in text.split(separator: "\n") {
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty,
              !line.lowercased().contains("checking mcp"),
              line.contains(": ")
        else { continue }
        // Find the LAST " - " (status separator) — URLs may contain dashes
        guard let dashRange = line.range(of: " - ", options: .backwards) else { continue }
        let beforeDash = String(line[..<dashRange.lowerBound])
        let rawStatus = String(line[dashRange.upperBound...])
        let status = rawStatus
            .replacingOccurrences(of: "✓ ", with: "")
            .replacingOccurrences(of: "! ", with: "")
            .replacingOccurrences(of: "✘ ", with: "")
            .replacingOccurrences(of: "✗ ", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let colonRange = beforeDash.range(of: ": ") else { continue }
        let name = String(beforeDash[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let details = String(beforeDash[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        result.append(ParsedMcpEntry(name: name, url: details, status: status))
    }
    return result
}

// MARK: - Design system

/// Tokens shared by every tab. Brand blue comes from the app icon (Carbon blue 60 in
/// light mode, blue 50 in dark). Accent is reserved for switches and the brand mark;
/// everything else stays neutral so the panel reads calm with 100 rows on screen.
enum Theme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x45 / 255, green: 0x89 / 255, blue: 0xFF / 255, alpha: 1)
            : NSColor(srgbRed: 0x0F / 255, green: 0x62 / 255, blue: 0xFE / 255, alpha: 1)
    })
    static let brandTop = Color(red: 0x45 / 255, green: 0x89 / 255, blue: 0xFF / 255)
    static let brandBottom = Color(red: 0x00 / 255, green: 0x43 / 255, blue: 0xCE / 255)

    /// Selected thumb surface: white in light mode, a lifted grey in dark.
    static let raised = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.15)
            : NSColor(white: 1, alpha: 1)
    })
    static let track = Color.primary.opacity(0.06)
    static let hover = Color.primary.opacity(0.055)
    static let hoverStrong = Color.primary.opacity(0.09)
    static let hairline = Color.primary.opacity(0.08)

    /// Surfaces (hover backgrounds, tab track) sit `rowInset` from the panel edge and pad
    /// `rowPadding` inside, so all text lines up on the `gutter`.
    static let gutter: CGFloat = 16
    static let rowInset: CGFloat = 8
    static let rowPadding: CGFloat = 8
    static let rowRadius: CGFloat = 8
}

extension Font {
    static let panelTitle = Font.system(size: 13, weight: .semibold)
    static let rowTitle = Font.system(size: 13, weight: .medium)
    static let rowSubtitle = Font.system(size: 11.5)
    static let rowMeta = Font.system(size: 10.5).monospacedDigit()
    static let sectionLabel = Font.system(size: 10.5, weight: .semibold)
    static let control = Font.system(size: 11, weight: .medium)
    static let code = Font.system(size: 10.5, weight: .medium, design: .monospaced)
}

enum Motion {
    /// Sliding thumbs (tab bar, skill states). Critically damped, no bounce.
    static let slide = Animation.spring(duration: 0.25, bounce: 0)
    /// Hover and color feedback. Fires constantly, so it stays short.
    static let hover = Animation.easeOut(duration: 0.12)
    /// Press-down scale.
    static let press = Animation.easeOut(duration: 0.12)
    /// Disclosure, list inserts/removals and the footer confirmation. Strong ease-out.
    static let reveal = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
}

private struct BlurFade: ViewModifier {
    let scale: CGFloat
    let blur: CGFloat
    let opacity: Double
    let y: CGFloat
    func body(content: Content) -> some View {
        content.scaleEffect(scale).blur(radius: blur).opacity(opacity).offset(y: y)
    }
}

extension AnyTransition {
    /// Contextual icon swap: scale 0.25 → 1, opacity 0 → 1, blur 4 → 0.
    static let iconSwap = AnyTransition.modifier(
        active: BlurFade(scale: 0.25, blur: 4, opacity: 0, y: 0),
        identity: BlurFade(scale: 1, blur: 0, opacity: 1, y: 0)
    )
    /// Label swap: a small rise with blur so the two labels read as one changing.
    static let textSwap = AnyTransition.modifier(
        active: BlurFade(scale: 1, blur: 2, opacity: 0, y: 3),
        identity: BlurFade(scale: 1, blur: 0, opacity: 1, y: 0)
    )
}

/// `scale(0.96)` on press so every button confirms the click.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Rounded hover surface inset from the panel edge. Content lands on the gutter.
private struct RowChrome: ViewModifier {
    let verticalPadding: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Theme.rowPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                    .fill(hovering ? Theme.hover : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .padding(.horizontal, Theme.rowInset)
    }
}

extension View {
    func rowChrome(verticalPadding: CGFloat = 7) -> some View {
        modifier(RowChrome(verticalPadding: verticalPadding))
    }
}

/// Square icon button with a hover surface. Neutral by design: destructive intent is
/// carried by the label and tooltip, not by red.
struct IconButton: View {
    let systemName: String
    let help: String
    var rotation: Angle = .zero
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .medium))
                .rotationEffect(rotation)
                .foregroundStyle(isEnabled ? (hovering ? Color.primary : Color.secondary) : Color.secondary.opacity(0.4))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering && isEnabled ? Theme.hoverStrong : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .help(help)
    }
}

/// Small monogram or symbol tile that anchors a row, tinted per item.
struct Tile: View {
    enum Glyph {
        case monogram(String)
        case symbol(String)
    }

    let glyph: Glyph
    let tint: Color
    var dimmed = false

    var body: some View {
        let color = dimmed ? Color.secondary : tint
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color.opacity(dimmed ? 0.12 : 0.15))
            switch glyph {
            case .monogram(let text):
                Text(verbatim: text).font(.system(size: 12, weight: .semibold, design: .rounded))
            case .symbol(let name):
                Image(systemName: name).font(.system(size: 11.5, weight: .medium))
            }
        }
        .foregroundStyle(color)
        .frame(width: 26, height: 26)
        .animation(Motion.hover, value: dimmed)
    }

    /// Stable per-name tint. Swift's `hashValue` is seeded per launch, so hash by hand.
    static func tint(for key: String) -> Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .cyan]
        let hash = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        return palette[hash % palette.count]
    }

    static func monogram(for name: String) -> String {
        String(name.first(where: { $0.isLetter || $0.isNumber }) ?? "•").uppercased()
    }
}

struct BrandMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Theme.brandTop, Theme.brandBottom], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
            BrandMark.glyph
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
        }
        .frame(width: 22, height: 22)
        .shadow(color: Theme.brandBottom.opacity(0.28), radius: 1.5, y: 1)
    }

    /// The backpack template from Resources/, or an SF Symbol under `swift run`.
    private static var glyph: some View {
        Group {
            if let image = NSImage(named: "MenuBarIcon") {
                Image(nsImage: image).resizable().renderingMode(.template).scaledToFit()
            } else {
                Image(systemName: "backpack.fill").resizable().scaledToFit()
            }
        }
    }
}

/// Uppercase group label with an optional count, sitting on the gutter.
struct SectionLabel: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            if let count {
                Text(verbatim: "\(count)").foregroundStyle(.quaternary)
            }
        }
        .font(.sectionLabel)
        .monospacedDigit()
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

/// Summary line at the top of a tab, with an optional trailing action.
struct ListToolbar<Trailing: View>: View {
    let summary: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: summary)
                .font(.rowSubtitle)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: 28)
        .padding(.leading, Theme.gutter)
        .padding(.trailing, Theme.rowInset + 4)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

extension ListToolbar where Trailing == EmptyView {
    init(summary: String) {
        self.init(summary: summary) { EmptyView() }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(verbatim: title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            if let message {
                Text(verbatim: message)
                    .font(.rowSubtitle)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 56)
    }
}

/// Inline `code` chip, used for the slash command in the footer.
struct CodeChip: View {
    let text: String
    var body: some View {
        Text(verbatim: text)
            .font(.code)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.track))
    }
}

/// Status dot with a soft halo so it reads at 7pt on vibrancy.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .background(Circle().fill(color.opacity(0.2)).frame(width: 12, height: 12))
            .frame(width: 12, height: 12)
    }
}

struct LoadoutSwitch: View {
    let isOn: Bool
    let onToggle: () -> Void
    var body: some View {
        Toggle("", isOn: Binding(get: { isOn }, set: { _ in onToggle() }))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)
            .tint(Theme.accent)
    }
}

// MARK: - Views

struct MenuView: View {
    @ObservedObject var store: AppStore
    @StateObject private var portsStore = PortsStore()
    @State private var tab: Tab
    @State private var refreshSpins = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let fixedHeight: CGFloat?

    init(store: AppStore, initialTab: Tab = .ports, fixedHeight: CGFloat? = nil) {
        self.store = store
        self._tab = State(initialValue: initialTab)
        self.fixedHeight = fixedHeight
    }

    enum Tab: String, CaseIterable, Identifiable {
        case ports = "Ports"
        case plugins = "Plugins"
        case skills = "Skills"
        case mcps = "MCP"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .ports: return "dot.radiowaves.left.and.right"
            case .plugins: return "puzzlepiece.extension"
            case .skills: return "sparkles"
            case .mcps: return "server.rack"
            }
        }
    }

    private func count(for tab: Tab) -> Int {
        switch tab {
        case .ports: return portsStore.ports.count
        case .plugins: return store.plugins.count
        case .skills: return store.skills.count
        case .mcps: return store.mcpServers.count + store.claudeAiIntegrations.count
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            TabBar(selection: $tab, count: count(for:))
                .padding(.horizontal, Theme.rowInset)
                .padding(.bottom, 10)

            if let error = store.lastError {
                ErrorBanner(message: error)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .ports: PortsSection(store: portsStore)
                    case .plugins: PluginsSection(store: store)
                    case .skills: SkillsSection(store: store)
                    case .mcps: MCPsSection(store: store)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
        }
        .frame(
            width: 440,
            height: fixedHeight ?? min(1100, (NSScreen.main?.visibleFrame.height ?? 1000) - 80)
        )
        .onAppear { portsStore.refresh() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            BrandMark()
            Text("Loadout").font(.panelTitle)
            Spacer()
            IconButton(
                systemName: "arrow.clockwise",
                help: "Reload from disk",
                rotation: .degrees(Double(refreshSpins) * 360)
            ) {
                if !reduceMotion {
                    withAnimation(.timingCurve(0.77, 0, 0.175, 1, duration: 0.6)) { refreshSpins += 1 }
                }
                store.reload()
                portsStore.refresh()
            }
        }
        .padding(.leading, Theme.gutter)
        .padding(.trailing, Theme.rowInset + 2)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            ZStack {
                if store.justCopied {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.iconSwap)
                } else {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(.tertiary)
                        .transition(.iconSwap)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .frame(width: 14)

            ZStack(alignment: .leading) {
                if store.justCopied {
                    HStack(spacing: 4) {
                        Text("Copied")
                        CodeChip(text: "/reload-plugins")
                        Text("· paste in Claude")
                    }
                    .transition(.textSwap)
                } else {
                    HStack(spacing: 4) {
                        Text("Changes copy")
                        CodeChip(text: "/reload-plugins")
                    }
                    .transition(.textSwap)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            QuitButton()
        }
        .animation(reduceMotion ? nil : Motion.reveal, value: store.justCopied)
        .padding(.leading, Theme.gutter)
        .padding(.trailing, Theme.rowInset + 2)
        .frame(height: 40)
    }
}

/// Segmented tab bar with a sliding raised thumb. Counts sit beside each label.
struct TabBar: View {
    @Binding var selection: MenuView.Tab
    let count: (MenuView.Tab) -> Int

    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MenuView.Tab.allCases) { item in
                let selected = item == selection
                Button {
                    selection = item
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .medium))
                        Text(item.rawValue)
                            .font(.system(size: 12, weight: .medium))
                        Text(verbatim: "\(count(item))")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.raised)
                                .shadow(color: .black.opacity(0.1), radius: 1, y: 0.5)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.black.opacity(0.04), lineWidth: 0.5)
                                )
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.track))
        .animation(reduceMotion ? nil : Motion.slide, value: selection)
    }
}

struct QuitButton: View {
    @State private var hovering = false

    var body: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            HStack(spacing: 5) {
                Text("Quit").foregroundStyle(hovering ? .primary : .secondary)
                Text("⌘Q").foregroundStyle(.tertiary)
            }
            .font(.control)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Theme.hoverStrong : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .keyboardShortcut("q")
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(verbatim: message)
                .font(.rowSubtitle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Color.orange.opacity(0.1)))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
        )
        .padding(.horizontal, Theme.rowInset)
        .padding(.bottom, 10)
    }
}

struct PluginsSection: View {
    @ObservedObject var store: AppStore

    var body: some View {
        if store.plugins.isEmpty {
            EmptyState(
                symbol: "puzzlepiece.extension",
                title: "No plugins installed",
                message: "Install one with /plugin in Claude Code."
            )
        } else {
            let enabled = store.plugins.filter(\.enabled).count
            ListToolbar(summary: "\(enabled) of \(store.plugins.count) enabled")
            ForEach(store.plugins) { plugin in
                PluginRow(plugin: plugin) { store.togglePlugin(plugin) }
            }
        }
    }
}

struct PluginRow: View {
    let plugin: InstalledPlugin
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Tile(glyph: .monogram(Tile.monogram(for: plugin.name)), tint: Tile.tint(for: plugin.name), dimmed: !plugin.enabled)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: plugin.name)
                    .font(.rowTitle)
                    .foregroundStyle(plugin.enabled ? .primary : .secondary)
                    .lineLimit(1)
                Text(verbatim: "\(plugin.version) · \(plugin.marketplace)")
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            LoadoutSwitch(isOn: plugin.enabled, onToggle: onToggle)
        }
        .rowChrome()
    }
}

struct SkillsSection: View {
    @ObservedObject var store: AppStore

    private var userSkills: [DiscoveredSkill] {
        store.skills.filter { $0.lock != .plugin }
    }

    private var pluginGroups: [(name: String, skills: [DiscoveredSkill])] {
        let pluginSkills = store.skills.filter { $0.lock == .plugin }
        let grouped = Dictionary(grouping: pluginSkills) { $0.source }
        return grouped.keys
            .sorted { $0.lowercased() < $1.lowercased() }
            .map { (name: $0, skills: grouped[$0] ?? []) }
    }

    /// "12 on · 3 trimmed · 8 off · 20 from plugins", skipping empty buckets.
    /// Plugin skills follow their plugin, so they get their own bucket.
    private var summary: String {
        var on = 0, trimmed = 0, off = 0
        for skill in userSkills {
            switch store.effectiveState(skill) {
            case .on: on += 1
            case .nameOnly, .userInvocableOnly: trimmed += 1
            case .off: off += 1
            }
        }
        let fromPlugins = store.skills.count - userSkills.count
        let parts = [(on, "on"), (trimmed, "trimmed"), (off, "off"), (fromPlugins, "from plugins")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if store.skills.isEmpty {
            EmptyState(
                symbol: "sparkles",
                title: "No skills found",
                message: "Skills live in ~/.claude/skills or inside installed plugins."
            )
        } else {
            ListToolbar(summary: summary) {
                if !userSkills.isEmpty {
                    TwoStepConfirmButton(
                        idleLabel: "Turn all off",
                        confirmLabel: "Confirm",
                        systemImage: "power",
                        action: { store.turnOffAllSkills() }
                    )
                }
            }

            if !userSkills.isEmpty {
                SectionLabel(title: "User", count: userSkills.count)
                ForEach(userSkills) { skill in
                    SkillRow(
                        skill: skill,
                        current: store.effectiveState(skill),
                        projects: store.skillProjectOverrides[skill.key] ?? [],
                        onPick: { store.setSkillOverride(skill, to: $0) }
                    )
                }
            }

            if !pluginGroups.isEmpty {
                SectionLabel(title: "Plugins", count: pluginGroups.count)
                ForEach(pluginGroups, id: \.name) { group in
                    PluginSkillGroup(name: group.name, skills: group.skills)
                }
                InlineNote(text: "Plugin skills ignore per-skill settings. Turn the plugin off in Plugins to drop them.")
            }

            if !store.deadOverrideKeys.isEmpty {
                DeadOverridesRow(count: store.deadOverrideKeys.count) {
                    store.removeDeadOverrides()
                }
            }
        }
    }
}

/// Leftover `plugin:skill` overrides from earlier versions. Claude Code never reads them.
struct DeadOverridesRow: View {
    let count: Int
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(count) plugin skill \(count == 1 ? "override has" : "overrides have") no effect")
                .font(.rowSubtitle)
                .foregroundStyle(.secondary)
                .help("Claude Code ignores skillOverrides for plugin skills. These keys in settings.json do nothing.")
            Spacer(minLength: 8)
            TwoStepConfirmButton(
                idleLabel: "Remove",
                confirmLabel: "Confirm",
                systemImage: "trash",
                action: onRemove
            )
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 8)
    }
}

struct PluginSkillGroup: View {
    let name: String
    let skills: [DiscoveredSkill]
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pluginEnabled: Bool { skills.first?.pluginEnabled ?? true }

    private var detail: String {
        let noun = skills.count == 1 ? "skill" : "skills"
        return (pluginEnabled ? "" : "Plugin off · ") + "\(skills.count) \(noun)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : Motion.reveal) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Tile(glyph: .monogram(Tile.monogram(for: name)), tint: Tile.tint(for: name), dimmed: !pluginEnabled)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: name)
                            .font(.rowTitle)
                            .foregroundStyle(pluginEnabled ? .primary : .secondary)
                            .lineLimit(1)
                        Text(verbatim: detail)
                            .font(.rowSubtitle)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .padding(.trailing, 4)
                }
                .rowChrome()
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(skills) { skill in
                        PluginSkillRow(skill: skill)
                    }
                }
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }
}

/// A plugin skill: listed for reference, with no controls. It is on exactly when its plugin is.
struct PluginSkillRow: View {
    let skill: DiscoveredSkill

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: skill.displayName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(skill.pluginEnabled ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Text(verbatim: skill.key))
            Spacer(minLength: 8)
            Text(skill.pluginEnabled ? "On with plugin" : "Off with plugin")
                .font(.rowSubtitle)
                .foregroundStyle(.tertiary)
                .help("Plugin skills ignore skillOverrides. Use the plugin's switch in Plugins.")
        }
        .padding(.leading, 36)
        .rowChrome(verticalPadding: 5)
    }
}

struct SkillRow: View {
    let skill: DiscoveredSkill
    let current: SkillOverride
    var projects: [ProjectOverride] = []
    let onPick: (SkillOverride) -> Void

    private var allowed: Set<SkillOverride> {
        skill.lock == .author ? [.userInvocableOnly, .off] : Set(SkillOverride.allCases)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: skill.displayName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(current == .off ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Text(verbatim: skill.key))
            Spacer(minLength: 8)
            if !projects.isEmpty {
                ProjectMarker(label: "\(projects.count) \(projects.count == 1 ? "project" : "projects")", detail: projectsDetail)
            }
            SkillStateSegments(current: current, allowed: allowed, onPick: onPick)
        }
        .animation(Motion.hover, value: current)
        .rowChrome(verticalPadding: 4)
    }

    private var projectsDetail: String {
        let lines = projects.map { "\($0.project): \($0.state.label)" }
        return "These projects set their own state, which wins over this one:\n" + lines.joined(separator: "\n")
    }
}

/// Quiet trailing note that a project's own settings differ, with the list in a tooltip.
struct ProjectMarker: View {
    let label: String
    let detail: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "folder")
                .font(.system(size: 9, weight: .semibold))
            Text(verbatim: label)
                .font(.rowMeta)
        }
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .fixedSize()
        .help(detail)
    }
}

/// Inline four-state segmented control (On / Name / Slash / Off) with a sliding thumb,
/// so every state is visible and one click away. States outside `allowed` are dimmed.
struct SkillStateSegments: View {
    let current: SkillOverride
    var allowed: Set<SkillOverride> = Set(SkillOverride.allCases)
    let onPick: (SkillOverride) -> Void

    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func shortLabel(_ state: SkillOverride) -> String {
        switch state {
        case .on: return "On"
        case .nameOnly: return "Name"
        case .userInvocableOnly: return "Slash"
        case .off: return "Off"
        }
    }

    private func tooltip(_ state: SkillOverride) -> String {
        if !allowed.contains(state) {
            return "This skill turns off model use itself, so it can only be Slash or Off"
        }
        switch state {
        case .on: return "On — listed with its description. The body loads only when used"
        case .nameOnly: return "Name — listed by name only, without the description"
        case .userInvocableOnly: return "Slash — hidden from the model. You can still type /name"
        case .off: return "Off — hidden from the model and from /"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SkillOverride.allCases) { state in
                let selected = state == current
                let enabled = allowed.contains(state)
                Button {
                    onPick(state)
                } label: {
                    Text(shortLabel(state))
                        .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? (state == .on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)) : AnyShapeStyle(enabled ? .secondary : .quaternary))
                        .lineLimit(1)
                        .frame(width: 40, height: 20)
                        .background {
                            if selected {
                                // Only On earns the accent; every reduced state stays neutral.
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(state == .on ? Theme.accent : Theme.raised)
                                    .shadow(color: .black.opacity(0.1), radius: 1, y: 0.5)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(Color.black.opacity(0.04), lineWidth: 0.5)
                                    )
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help(tooltip(state))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.track))
        .animation(reduceMotion ? nil : Motion.slide, value: current)
    }
}

/// "Off in 3" for a server that `/mcp` disabled in some projects while it's allowed here.
func offLabel(_ projects: [String]) -> String { "Off in \(projects.count)" }

func offDetail(_ projects: [String]) -> String {
    "Turned off with /mcp in \(projects.count == 1 ? "this project" : "these projects"):\n"
        + projects.joined(separator: "\n")
}

struct MCPsSection: View {
    @ObservedObject var store: AppStore

    private var summary: String {
        let active = store.mcpServers.filter(\.enabled).count
            + store.claudeAiIntegrations.filter { !$0.denied }.count
        let total = store.mcpServers.count + store.claudeAiIntegrations.count
        return "\(active) of \(total) allowed"
    }

    var body: some View {
        ListToolbar(summary: summary)

        SectionLabel(title: "User", count: store.mcpServers.count)
        if store.mcpServers.isEmpty {
            InlineNote(text: "No local MCP servers in ~/.claude.json.")
        } else {
            ForEach(store.mcpServers) { server in
                MCPRow(server: server) { store.toggleMCPServer(server) }
            }
        }

        SectionLabel(title: "claude.ai", count: store.claudeAiIntegrations.isEmpty ? nil : store.claudeAiIntegrations.count)
        if store.loadingClaudeAi && store.claudeAiIntegrations.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking connections…").font(.rowSubtitle).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 8)
        } else if store.claudeAiIntegrations.isEmpty {
            InlineNote(text: "No claude.ai integrations found.")
        } else {
            ForEach(store.claudeAiIntegrations) { integration in
                ClaudeAiRow(integration: integration) {
                    store.toggleClaudeAiIntegration(integration)
                }
            }
        }
    }
}

/// One-line empty note inside a subsection, where a full empty state would be too loud.
struct InlineNote: View {
    let text: String
    var body: some View {
        Text(verbatim: text)
            .font(.rowSubtitle)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 6)
    }
}

struct ClaudeAiRow: View {
    let integration: ClaudeAiIntegration
    let onToggle: () -> Void

    private var symbol: String {
        switch integration.name {
        case "Gmail": return "envelope.fill"
        case "Google Calendar": return "calendar"
        case "Google Drive": return "folder.fill"
        case "Slack": return "number"
        case "Miro": return "square.on.square"
        case "Figma": return "paintbrush.pointed.fill"
        default: return "cloud.fill"
        }
    }

    private var tint: Color {
        switch integration.name {
        case "Gmail": return .red
        case "Google Calendar": return .blue
        case "Google Drive": return .green
        case "Slack": return .purple
        case "Miro": return .yellow
        case "Figma": return .pink
        default: return .gray
        }
    }

    private var statusColor: Color {
        let status = integration.status.lowercased()
        if integration.denied { return .secondary }
        if status.contains("auth") { return .orange }
        if status.contains("connected") && !status.contains("not") { return .green }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 10) {
            Tile(glyph: .symbol(symbol), tint: tint, dimmed: integration.denied)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: integration.name)
                    .font(.rowTitle)
                    .foregroundStyle(integration.denied ? .secondary : .primary)
                HStack(spacing: 2) {
                    StatusDot(color: statusColor)
                    Text(verbatim: integration.status)
                        .font(.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, -3)
            }
            Spacer(minLength: 8)
            if !integration.denied && !integration.offInProjects.isEmpty {
                ProjectMarker(label: offLabel(integration.offInProjects), detail: offDetail(integration.offInProjects))
            }
            LoadoutSwitch(isOn: !integration.denied, onToggle: onToggle)
        }
        .rowChrome()
    }
}

struct MCPRow: View {
    let server: LocalMCPServer
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Tile(
                glyph: .symbol(server.kind == "stdio" ? "terminal.fill" : "globe"),
                tint: Tile.tint(for: server.name),
                dimmed: !server.enabled
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: server.name)
                    .font(.rowTitle)
                    .foregroundStyle(server.enabled ? .primary : .secondary)
                HStack(spacing: 6) {
                    Text(verbatim: server.kind.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.tertiary)
                    Text(verbatim: server.summary)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if server.enabled && !server.offInProjects.isEmpty {
                ProjectMarker(label: offLabel(server.offInProjects), detail: offDetail(server.offInProjects))
            }
            LoadoutSwitch(isOn: server.enabled, onToggle: onToggle)
        }
        .rowChrome()
    }
}

// MARK: - Debug snapshots

#if DEBUG
/// `LOADOUT_SNAPSHOT=/some/dir .build/debug/Loadout` renders every tab in light
/// and dark into PNGs, then exits. Lets you review the panel without clicking
/// through the menu bar. Debug builds only.
enum SnapshotRenderer {
    @MainActor private static var windows: [NSWindow] = []

    @MainActor static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["LOADOUT_SNAPSHOT"] else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let outDir = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let store = AppStore(readOnly: true)
        var jobs: [(name: String, view: NSView)] = []
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for tab in MenuView.Tab.allCases {
                let root = MenuView(store: store, initialTab: tab, fixedHeight: 720)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: root)
                let window = NSWindow(
                    contentRect: NSRect(x: -4000, y: -4000, width: 440, height: 720),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                window.orderFrontRegardless()
                windows.append(window)
                jobs.append(("\(tab.rawValue.lowercased())-\(appearanceName)", host))
            }
        }

        // Give the async loaders (claude mcp list, port scan, health probes) time to land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            for job in jobs {
                job.view.layoutSubtreeIfNeeded()
                guard let rep = job.view.bitmapImageRepForCachingDisplay(in: job.view.bounds) else { continue }
                job.view.cacheDisplay(in: job.view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: outDir.appendingPathComponent("\(job.name).png"))
                }
            }
            exit(0)
        }
        app.run()
    }
}
#endif
