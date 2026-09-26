import SwiftUI
import AppKit

@main
struct LoadoutApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            Image(systemName: "puzzlepiece.extension.fill")
        }
        .menuBarExtraStyle(.window)
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

struct DiscoveredSkill: Identifiable, Hashable {
    var id: String { key }
    let key: String              // "compose" or "impeccable:polish"
    let displayName: String
    let source: String           // "user" or plugin name
    let pluginEnabled: Bool       // if false, the skill is dormant regardless of override
}

struct LocalMCPServer: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let kind: String              // stdio, http, sse
    let summary: String           // command or url, truncated
    var enabled: Bool
}

struct ClaudeAiIntegration: Identifiable, Hashable {
    var id: String { name }
    let name: String              // "Gmail", "Slack", "Google Drive", etc.
    let url: String
    let status: String            // "Connected", "Needs authentication", etc.
    var denied: Bool
}

// MARK: - Store

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var plugins: [InstalledPlugin] = []
    @Published private(set) var skills: [DiscoveredSkill] = []
    @Published private(set) var skillOverrides: [String: SkillOverride] = [:]
    @Published private(set) var mcpServers: [LocalMCPServer] = []
    @Published private(set) var claudeAiIntegrations: [ClaudeAiIntegration] = []
    @Published private(set) var loadingClaudeAi: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastToggledAt: Date?

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var installedUrl: URL { home.appendingPathComponent(".claude/plugins/installed_plugins.json") }
    private var settingsUrl: URL { home.appendingPathComponent(".claude/settings.json") }
    private var claudeJsonUrl: URL { home.appendingPathComponent(".claude.json") }
    private var userSkillsDir: URL { home.appendingPathComponent(".claude/skills") }

    init() { reload() }

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
                let name = url.lastPathComponent
                found.append(DiscoveredSkill(
                    key: name,
                    displayName: name,
                    source: "user",
                    pluginEnabled: true
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
                    pluginEnabled: plugin.enabled
                ))
            }
        }

        skills = found.sorted {
            ($0.source.lowercased(), $0.displayName.lowercased())
                < ($1.source.lowercased(), $1.displayName.lowercased())
        }
    }

    func setSkillOverride(_ skill: DiscoveredSkill, to value: SkillOverride) {
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

    // MARK: Local MCP servers

    private func loadMCPs() throws {
        let claudeJson = try readJSON(claudeJsonUrl)
        let active = claudeJson["mcpServers"] as? [String: [String: Any]] ?? [:]
        let disabled = claudeJson["_disabledMcpServers"] as? [String: [String: Any]] ?? [:]

        var seen: Set<String> = []
        var found: [LocalMCPServer] = []
        for (name, cfg) in active {
            seen.insert(name)
            found.append(makeServer(name: name, cfg: cfg, enabled: true))
        }
        for (name, cfg) in disabled where !seen.contains(name) {
            found.append(makeServer(name: name, cfg: cfg, enabled: false))
        }
        mcpServers = found.sorted { $0.name.lowercased() < $1.name.lowercased() }
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
                name: item.name, url: item.url, status: status, denied: denied
            )
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
        loadingClaudeAi = false
    }

    private func applyDenyStateToClaudeAi() {
        let denyUrls = readDenyUrls()
        claudeAiIntegrations = claudeAiIntegrations.map { entry in
            var updated = entry
            updated = ClaudeAiIntegration(
                name: entry.name,
                url: entry.url,
                status: entry.status,
                denied: denyUrls.contains(entry.url)
            )
            return updated
        }
    }

    private func readDenyUrls() -> Set<String> {
        guard let json = try? readJSON(settingsUrl),
              let deny = json["deniedMcpServers"] as? [[String: Any]] else { return [] }
        return Set(deny.compactMap { $0["serverUrl"] as? String })
    }

    func toggleClaudeAiIntegration(_ integration: ClaudeAiIntegration) {
        do {
            try writeSettings { json in
                var deny = json["deniedMcpServers"] as? [[String: Any]] ?? []
                if integration.denied {
                    deny.removeAll { ($0["serverUrl"] as? String) == integration.url }
                } else {
                    deny.append(["serverUrl": integration.url])
                }
                if deny.isEmpty {
                    json.removeValue(forKey: "deniedMcpServers")
                } else {
                    json["deniedMcpServers"] = deny
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
            try writeClaudeJson { json in
                var active = json["mcpServers"] as? [String: Any] ?? [:]
                var disabled = json["_disabledMcpServers"] as? [String: Any] ?? [:]
                if server.enabled {
                    if let cfg = active.removeValue(forKey: server.name) {
                        disabled[server.name] = cfg
                    }
                } else {
                    if let cfg = disabled.removeValue(forKey: server.name) {
                        active[server.name] = cfg
                    }
                }
                json["mcpServers"] = active
                if disabled.isEmpty {
                    json.removeValue(forKey: "_disabledMcpServers")
                } else {
                    json["_disabledMcpServers"] = disabled
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
        lastToggledAt = Date()
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

// MARK: - Views

struct MenuView: View {
    @ObservedObject var store: AppStore
    @State private var tab: Tab = .plugins

    enum Tab: String, CaseIterable, Identifiable {
        case plugins = "Plugins"
        case skills = "Skills"
        case mcps = "MCP"
        var id: String { rawValue }
    }

    private func count(for tab: Tab) -> Int {
        switch tab {
        case .plugins: return store.plugins.count
        case .skills: return store.skills.count
        case .mcps: return store.mcpServers.count + store.claudeAiIntegrations.count
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { item in
                    Text("\(item.rawValue) \(count(for: item))").tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let error = store.lastError {
                ErrorBanner(message: error)
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .plugins: PluginsSection(store: store)
                    case .skills: SkillsSection(store: store)
                    case .mcps: MCPsSection(store: store)
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(
            width: 360,
            height: min(1100, (NSScreen.main?.visibleFrame.height ?? 1000) - 80)
        )
    }

    private var header: some View {
        HStack {
            Text("Loadout")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Refresh from disk")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let toggledAt = store.lastToggledAt, Date().timeIntervalSince(toggledAt) < 8 {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text("Copied ").font(.system(size: 11)).foregroundStyle(.secondary)
                    + Text("/reload-plugins").font(.system(size: 11, design: .monospaced))
                    + Text(" — paste in active session").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("Toggling copies ").font(.system(size: 11)).foregroundStyle(.secondary)
                + Text("/reload-plugins").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                + Text(" — paste it in your active Claude session.").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundStyle(.orange)
            Text(message).font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct PluginsSection: View {
    @ObservedObject var store: AppStore
    var body: some View {
        if store.plugins.isEmpty {
            Text("No installed plugins.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
        } else {
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
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name).font(.system(size: 12, weight: .medium))
                Text("\(plugin.version) · \(plugin.marketplace)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { plugin.enabled }, set: { _ in onToggle() }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct SkillsSection: View {
    @ObservedObject var store: AppStore

    private var userSkills: [DiscoveredSkill] {
        store.skills.filter { $0.source == "user" }
    }

    private var pluginGroups: [(name: String, skills: [DiscoveredSkill])] {
        let pluginSkills = store.skills.filter { $0.source != "user" }
        let grouped = Dictionary(grouping: pluginSkills) { $0.source }
        return grouped.keys
            .sorted { $0.lowercased() < $1.lowercased() }
            .map { (name: $0, skills: grouped[$0] ?? []) }
    }

    var body: some View {
        if store.skills.isEmpty {
            Text("No skills found.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
        } else {
            if !userSkills.isEmpty {
                SubsectionLabel(text: "User")
                ForEach(userSkills) { skill in
                    SkillRow(
                        skill: skill,
                        current: store.skillOverrides[skill.key] ?? .on,
                        onPick: { store.setSkillOverride(skill, to: $0) }
                    )
                }
            }

            if !pluginGroups.isEmpty {
                SubsectionLabel(text: "Plugins")
                ForEach(pluginGroups, id: \.name) { group in
                    PluginSkillGroup(name: group.name, skills: group.skills, store: store)
                }
            }
        }
    }
}

struct PluginSkillGroup: View {
    let name: String
    let skills: [DiscoveredSkill]
    @ObservedObject var store: AppStore
    @State private var expanded = false

    private var pluginEnabled: Bool { skills.first?.pluginEnabled ?? true }

    private var adjustedCount: Int {
        skills.filter { (store.skillOverrides[$0.key] ?? .on) != .on }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(pluginEnabled ? .primary : .tertiary)
                    if !pluginEnabled {
                        Text("disabled").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if adjustedCount > 0 {
                        Text("\(adjustedCount) set")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    Text("\(skills.count)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(skills) { skill in
                    SkillRow(
                        skill: skill,
                        current: store.skillOverrides[skill.key] ?? .on,
                        onPick: { store.setSkillOverride(skill, to: $0) }
                    )
                    .padding(.leading, 14)
                }
            }
        }
    }
}

struct SkillRow: View {
    let skill: DiscoveredSkill
    let current: SkillOverride
    let onPick: (SkillOverride) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(skill.pluginEnabled ? .primary : .tertiary)
                Text(skill.source).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(SkillOverride.allCases) { state in
                    Button {
                        onPick(state)
                    } label: {
                        HStack {
                            Image(systemName: state == current ? "checkmark" : "")
                            Text(state.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: current.symbol).font(.system(size: 10))
                    Text(current.label).font(.system(size: 11))
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!skill.pluginEnabled)
            .help(skill.pluginEnabled
                  ? "On / Name only / Slash only / Off"
                  : "Plugin disabled — enable plugin to control this skill")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .opacity(skill.pluginEnabled ? 1 : 0.6)
    }
}

struct MCPsSection: View {
    @ObservedObject var store: AppStore
    var body: some View {
        SubsectionLabel(text: "User")
        if store.mcpServers.isEmpty {
            Text("None.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
        } else {
            ForEach(store.mcpServers) { server in
                MCPRow(server: server) { store.toggleMCPServer(server) }
            }
        }

        SubsectionLabel(text: "claude.ai")
        if store.loadingClaudeAi && store.claudeAiIntegrations.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        } else if store.claudeAiIntegrations.isEmpty {
            Text("None connected.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
        } else {
            ForEach(store.claudeAiIntegrations) { integration in
                ClaudeAiRow(integration: integration) {
                    store.toggleClaudeAiIntegration(integration)
                }
            }
        }
    }
}

struct SubsectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

struct ClaudeAiRow: View {
    let integration: ClaudeAiIntegration
    let onToggle: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(integration.name).font(.system(size: 12, weight: .medium))
                Text(integration.status)
                    .font(.system(size: 10))
                    .foregroundStyle(integration.status.lowercased().contains("connected") ? .green : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle(
                "",
                isOn: Binding(get: { !integration.denied }, set: { _ in onToggle() })
            )
            .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct MCPRow: View {
    let server: LocalMCPServer
    let onToggle: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.system(size: 12, weight: .medium))
                Text("\(server.kind) · \(server.summary)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { server.enabled }, set: { _ in onToggle() }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
