import Foundation

/// Applies a choice to whichever files a tool reads. Every method writes through
/// `writer`, so one user action undoes as one step.
final class Engine {
    let paths: Paths
    let writer: ConfigWriter
    var state: AppState

    init(paths: Paths, state: AppState, writer: ConfigWriter) {
        self.paths = paths
        self.state = state
        self.writer = writer
    }

    private var loader: InventoryLoader { InventoryLoader(paths: paths, state: state) }

    // MARK: Services

    func setService(_ service: Service, on: Bool, scope: Scope) throws {
        for control in service.switchable {
            try set(control, on: on, scope: scope)
        }
    }

    func resetService(_ service: Service, scope: Scope) throws {
        for control in service.controls where control.setHere {
            try reset(control, scope: scope)
        }
    }

    func set(_ control: Control, on: Bool, scope: Scope) throws {
        switch control.target {
        case .claudePlugin(let id):
            try setClaudePlugin(id, on: on, scope: scope)
        case .claudeServer(let ref):
            try setClaudeServer(ref, on: on, scope: scope)
        case .codexPlugin(let id):
            try setCodex(["plugins", id], on: on, scope: scope)
        case .codexApp(let id):
            try setCodex(["apps", id], on: on, scope: scope)
        case .codexServer(let name, let definition, let definedGlobally):
            try setCodexServer(name, definition: definition, definedGlobally: definedGlobally, on: on, scope: scope)
        case .antigravityServer(let name, let definition, _):
            try setAntigravity(name, definition: definition, on: on, scope: scope)
        case .cursorServer:
            break
        }
    }

    func reset(_ control: Control, scope: Scope) throws {
        guard let project = scope.projectPath else { return }
        switch control.target {
        case .claudePlugin(let id):
            try editLocal(project) { json in
                var map = json["enabledPlugins"] as? [String: Bool] ?? [:]
                map.removeValue(forKey: id)
                Self.store(&json, "enabledPlugins", map.isEmpty ? nil : map)
            }
        case .claudeServer(let ref):
            try editLocal(project) { json in
                Self.remove(&json, "allowedMcpServers", ref, forAllow: true)
                Self.remove(&json, "deniedMcpServers", ref, forAllow: false)
            }
            try clearSlashDisable(ref, project: project)
        case .codexPlugin(let id):
            try resetCodex(["plugins", id], project: project)
        case .codexApp(let id):
            try resetCodex(["apps", id], project: project)
        case .codexServer(let name, _, let definedGlobally):
            try editCodexProject(project) { doc in
                let path = ["mcp_servers", name]
                doc.remove(path, "enabled")
                if !definedGlobally || doc.isEmpty(path) { doc.removeSection(path) }
            }
        case .antigravityServer(let name, _, _):
            try editWorkspace(project) { servers in servers.removeValue(forKey: name) }
            state.antigravityOff[project]?.removeValue(forKey: name)
            if state.antigravityOff[project]?.isEmpty == true { state.antigravityOff.removeValue(forKey: project) }
            try state.save(paths)
        case .cursorServer:
            break
        }
    }

    // MARK: Claude Code

    private func editUser(_ mutate: (inout [String: Any]) -> Void) throws {
        try writer.editJSON(paths.claudeSettings, mutate)
    }

    private func editLocal(_ project: String, _ mutate: (inout [String: Any]) -> Void) throws {
        try writer.editJSON(paths.claudeLocal(project), removeIfEmpty: true, mutate)
        GitExclude.exclude(".claude/settings.local.json", in: paths.folder(project))
    }

    private static func store(_ json: inout [String: Any], _ key: String, _ value: Any?) {
        if let value { json[key] = value } else { json.removeValue(forKey: key) }
    }

    private static func remove(_ json: inout [String: Any], _ key: String, _ ref: ClaudeServerRef, forAllow: Bool) {
        guard var list = json[key] as? [[String: Any]] else { return }
        let before = list.count
        list.removeAll { ClaudeRules.entry($0, matches: ref, forAllow: forAllow) }
        guard list.count != before else { return }
        // Project lists go away when empty. The user allowlist stays: empty means default-off.
        store(&json, key, list.isEmpty ? nil : list)
    }

    private func setClaudePlugin(_ id: String, on: Bool, scope: Scope) throws {
        let apply: (inout [String: Any]) -> Void = { json in
            var map = json["enabledPlugins"] as? [String: Bool] ?? [:]
            map[id] = on
            json["enabledPlugins"] = map
        }
        if let project = scope.projectPath {
            try editLocal(project, apply)
        } else {
            try editUser(apply)
        }
    }

    private func setClaudeServer(_ ref: ClaudeServerRef, on: Bool, scope: Scope) throws {
        let settings = try loader.claudeSettings(scope: scope)
        guard let project = scope.projectPath else {
            try setClaudeServerDefault(ref, on: on, settings: settings)
            return
        }
        try editLocal(project) { json in
            if on {
                Self.remove(&json, "deniedMcpServers", ref, forAllow: false)
                if settings.allowlistActive && !settings.allowedAbove(ref),
                   !ClaudeRules.anyMatch(json["allowedMcpServers"] as? [[String: Any]] ?? [], ref, forAllow: true),
                   let rule = ref.allowRule {
                    var allow = json["allowedMcpServers"] as? [[String: Any]] ?? []
                    allow.append(rule.json)
                    json["allowedMcpServers"] = allow
                }
            } else {
                Self.remove(&json, "allowedMcpServers", ref, forAllow: true)
                var deny = json["deniedMcpServers"] as? [[String: Any]] ?? []
                if !ClaudeRules.anyMatch(deny, ref, forAllow: false) {
                    deny.append(ref.denyRule.json)
                    json["deniedMcpServers"] = deny
                }
            }
        }
        if on { try clearSlashDisable(ref, project: project) }
    }

    private func setClaudeServerDefault(_ ref: ClaudeServerRef, on: Bool, settings: ClaudeSettings) throws {
        try editUser { json in
            if settings.hasUserAllowlist {
                var allow = json["allowedMcpServers"] as? [[String: Any]] ?? []
                allow.removeAll { ClaudeRules.entry($0, matches: ref, forAllow: true) }
                if on {
                    Self.remove(&json, "deniedMcpServers", ref, forAllow: false)
                    if let rule = ref.allowRule { allow.append(rule.json) }
                }
                json["allowedMcpServers"] = allow
            } else if on {
                Self.remove(&json, "deniedMcpServers", ref, forAllow: false)
            } else {
                var deny = json["deniedMcpServers"] as? [[String: Any]] ?? []
                if !ClaudeRules.anyMatch(deny, ref, forAllow: false) {
                    deny.append(ref.denyRule.json)
                    json["deniedMcpServers"] = deny
                }
            }
        }
    }

    /// Takes a server off `/mcp`'s per-project list. `~/.claude.json` is rewritten by
    /// running sessions all the time, so undo re-adds the names instead of restoring it.
    private func clearSlashDisable(_ ref: ClaudeServerRef, project: String) throws {
        let settings = try loader.claudeSettings(scope: .project(project))
        let removed = settings.slashDisabled.intersection(ref.names)
        guard !removed.isEmpty else { return }
        try writer.editJSONTargeted(paths.claudeJson, { json in
            Self.updateSlashList(&json, project: project) { $0.removeAll { removed.contains($0) } }
        }, inverse: { json in
            Self.updateSlashList(&json, project: project) { $0.append(contentsOf: removed.sorted()) }
        })
    }

    private static func updateSlashList(_ json: inout [String: Any], project: String, _ change: (inout [String]) -> Void) {
        var projects = json["projects"] as? [String: Any] ?? [:]
        var entry = projects[project] as? [String: Any] ?? [:]
        var list = entry["disabledMcpServers"] as? [String] ?? []
        change(&list)
        entry["disabledMcpServers"] = list
        projects[project] = entry
        json["projects"] = projects
    }

    // MARK: Codex

    private func editToml(_ url: URL, removeIfBlank: Bool, _ mutate: (inout TOMLDocument) -> Void) throws {
        var doc = TOMLDocument((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        mutate(&doc)
        try writer.writeText(doc.text, to: url, removeIfBlank: removeIfBlank)
    }

    private func editCodexProject(_ project: String, _ mutate: (inout TOMLDocument) -> Void) throws {
        try editToml(paths.codexProject(project), removeIfBlank: true, mutate)
        GitExclude.exclude(".codex/config.toml", in: paths.folder(project))
    }

    private func setCodex(_ path: [String], on: Bool, scope: Scope) throws {
        if let project = scope.projectPath {
            try editCodexProject(project) { $0.set(path, "enabled", rawValue: on ? "true" : "false") }
        } else {
            try editToml(paths.codexConfig, removeIfBlank: false) { $0.set(path, "enabled", rawValue: on ? "true" : "false") }
        }
    }

    private func resetCodex(_ path: [String], project: String) throws {
        try editCodexProject(project) { doc in
            doc.remove(path, "enabled")
            if doc.isEmpty(path) { doc.removeSection(path) }
        }
    }

    private func setCodexServer(_ name: String, definition: ServerDefinition?, definedGlobally: Bool, on: Bool, scope: Scope) throws {
        let path = ["mcp_servers", name]
        let flag = on ? "true" : "false"
        guard let project = scope.projectPath else {
            try editToml(paths.codexConfig, removeIfBlank: false) { $0.set(path, "enabled", rawValue: flag) }
            return
        }
        try editCodexProject(project) { doc in
            if !definedGlobally, doc.section(path) == nil, let definition {
                if let args = definition.command != nil && !definition.args.isEmpty ? definition.args : nil {
                    doc.set(path, "args", rawValue: TOMLDocument.array(args))
                }
                if let command = definition.command { doc.set(path, "command", rawValue: TOMLDocument.quote(command)) }
                if let url = definition.url { doc.set(path, "url", rawValue: TOMLDocument.quote(url)) }
            }
            doc.set(path, "enabled", rawValue: flag)
        }
    }

    /// Adds the project to Codex's trusted list. Only ever called from an explicit action.
    func trustCodex(project: String) throws {
        try editToml(paths.codexConfig, removeIfBlank: false) { doc in
            doc.set(["projects", project], "trust_level", rawValue: TOMLDocument.quote("trusted"))
        }
    }

    // MARK: Antigravity

    private func editWorkspace(_ project: String, _ mutate: (inout [String: Any]) -> Void) throws {
        let url = paths.antigravityWorkspace(project)
        try writer.editJSON(url, removeIfEmpty: true) { json in
            var servers = json["mcpServers"] as? [String: Any] ?? [:]
            mutate(&servers)
            if servers.isEmpty {
                json.removeValue(forKey: "mcpServers")
            } else {
                json["mcpServers"] = servers
            }
        }
        GitExclude.exclude(".agents/mcp_config.json", in: paths.folder(project))
    }

    /// In a real session a workspace server marked `disabled: true` still started, so
    /// off means removing the entry. It's remembered so On can restore it.
    private func setAntigravity(_ name: String, definition: ServerDefinition?, on: Bool, scope: Scope) throws {
        guard let project = scope.projectPath else {
            try writer.editJSON(paths.antigravityConfig) { json in
                var servers = json["mcpServers"] as? [String: [String: Any]] ?? [:]
                var entry = servers[name] ?? [:]
                if on { entry.removeValue(forKey: "disabled") } else { entry["disabled"] = true }
                servers[name] = entry
                json["mcpServers"] = servers
            }
            return
        }
        guard let definition else { return }
        try editWorkspace(project) { servers in
            if on {
                servers[name] = definition.antigravityJSON
            } else {
                servers.removeValue(forKey: name)
            }
        }
        if on {
            state.antigravityOff[project]?.removeValue(forKey: name)
            if state.antigravityOff[project]?.isEmpty == true { state.antigravityOff.removeValue(forKey: project) }
        } else {
            state.antigravityOff[project, default: [:]][name] = AppState.StoredDefinition(
                url: definition.url, command: definition.command, args: definition.args
            )
        }
        try state.save(paths)
    }

    // MARK: Skills

    func setSkill(_ skill: SkillItem, to value: SkillOverride, scope: Scope) throws {
        try setSkills([skill], to: value, scope: scope)
    }

    func setSkills(_ skills: [SkillItem], to value: SkillOverride, scope: Scope) throws {
        let apply: (inout [String: Any]) -> Void = { json in
            var map = json["skillOverrides"] as? [String: String] ?? [:]
            for skill in skills {
                // Under All projects "on" is the absence of a setting. In a project it
                // has to be written, or the default could still turn the skill off.
                if value == .on && scope == .allProjects {
                    map.removeValue(forKey: skill.key)
                } else {
                    map[skill.key] = value.rawValue
                }
            }
            Self.store(&json, "skillOverrides", map.isEmpty ? nil : map)
        }
        if let project = scope.projectPath {
            try editLocal(project, apply)
            try syncSkillLinks(project: project)
        } else {
            try editUser(apply)
            try syncLinkedProjects()
        }
    }

    func resetSkill(_ skill: SkillItem, project: String) throws {
        try editLocal(project) { json in
            var map = json["skillOverrides"] as? [String: String] ?? [:]
            map.removeValue(forKey: skill.key)
            Self.store(&json, "skillOverrides", map.isEmpty ? nil : map)
        }
        try syncSkillLinks(project: project)
    }

    /// Removes the `plugin:skill` keys earlier versions wrote. They never had an effect.
    func removeDeadOverrides(_ keys: [String]) throws {
        let dead = Set(keys)
        try editUser { json in
            var map = json["skillOverrides"] as? [String: String] ?? [:]
            map = map.filter { !dead.contains($0.key) }
            Self.store(&json, "skillOverrides", map.isEmpty ? nil : map)
        }
    }

    /// Versions before 0.1 hid servers under `_disabledMcpServers` in `~/.claude.json`.
    /// They go back to `mcpServers`, off.
    func restoreParkedServers() throws {
        let claude = try readJSONObject(paths.claudeJson)
        guard let parked = claude["_disabledMcpServers"] as? [String: Any] else { return }
        let backup = paths.home.appendingPathComponent(".claude.json.loadout-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: paths.claudeJson, to: backup)
        }
        let user = try readJSONObject(paths.claudeSettings)
        if user["allowedMcpServers"] == nil, !parked.isEmpty {
            try editUser { json in
                var deny = json["deniedMcpServers"] as? [[String: Any]] ?? []
                for name in parked.keys.sorted() where !deny.contains(where: { $0["serverName"] as? String == name }) {
                    deny.append(["serverName": name])
                }
                json["deniedMcpServers"] = deny
            }
        }
        try writer.editJSON(paths.claudeJson) { json in
            var active = json["mcpServers"] as? [String: Any] ?? [:]
            for (name, config) in parked where active[name] == nil { active[name] = config }
            json["mcpServers"] = active
            json.removeValue(forKey: "_disabledMcpServers")
        }
    }

    /// Clears every choice a project made in the files Loadout writes.
    func resetProject(_ project: String, inventory: Inventory) throws {
        for service in inventory.services { try resetService(service, scope: .project(project)) }
        for skill in inventory.skills where skill.setHere { try resetSkill(skill, project: project) }
    }

    // MARK: Skill links for other tools

    private var linksSkills: Bool {
        [Harness.codex, .antigravity, .cursor].contains { state.manages($0, paths: paths) }
    }

    /// Codex, Antigravity and Cursor read `.agents/skills`, and none has a per-skill
    /// switch that works per project. So a skill reaches them by being linked there.
    /// Only links pointing at a skill Loadout knows are ever removed: real folders and
    /// other people's links are left alone.
    func syncSkillLinks(project: String) throws {
        guard linksSkills else { return }
        let scope = Scope.project(project)
        let skills = try loader.load(scope: scope).skills
        let dir = paths.agentSkills(project)
        let fm = FileManager.default
        // Compared by parent folder with symlinks resolved: /var and /private/var are one
        // place, and a skill folder may itself be a link into a dotfiles repo.
        let managedRoots = [paths.userSkills, paths.projectSkills(project)].map { $0.resolvingSymlinksInPath().path }
        let desired = Dictionary(
            skills.filter { $0.state == .on }.map { ($0.key, $0.folder) },
            uniquingKeysWith: { _, new in new }
        )

        var existing: [String: String] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            if let destination = try? fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent(name).path) {
                existing[name] = destination
            }
        }
        for (name, destination) in existing where desired[name] == nil {
            let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().resolvingSymlinksInPath().path
            guard managedRoots.contains(parent) else { continue }
            try writer.removeSymlink(dir.appendingPathComponent(name))
        }
        for (name, folder) in desired where existing[name] == nil {
            let link = dir.appendingPathComponent(name)
            // A real folder with this name belongs to the repo. Leave it.
            if fm.fileExists(atPath: link.path) { continue }
            try writer.symlink(link, to: folder)
            GitExclude.exclude(".agents/skills/\(name)", in: paths.folder(project))
        }
        if !state.linkedProjects.contains(project) {
            state.linkedProjects.append(project)
            try state.save(paths)
        }
    }

    private func syncLinkedProjects() throws {
        let fm = FileManager.default
        for project in state.linkedProjects where fm.fileExists(atPath: project) {
            try syncSkillLinks(project: project)
        }
    }

    // MARK: Presets

    func snapshotPreset(name: String, inventory: Inventory) -> Preset {
        var services: [String: Bool] = [:]
        for service in inventory.services where !service.switchable.isEmpty {
            services[service.id] = service.isOn
        }
        var skills: [String: SkillOverride] = [:]
        for skill in inventory.skills { skills[skill.key] = skill.state }
        return Preset(name: name, services: services, skills: skills)
    }

    func apply(_ preset: Preset, scope: Scope, inventory: Inventory) throws {
        for service in inventory.services {
            guard let wanted = preset.services[service.id], wanted != service.isOn || service.mainState == .mixed else { continue }
            try setService(service, on: wanted, scope: scope)
        }
        for skill in inventory.skills {
            guard let wanted = preset.skills[skill.key], wanted != skill.state else { continue }
            let value = skill.lock == .author && wanted == .on ? SkillOverride.userInvocableOnly : wanted
            try setSkill(skill, to: value, scope: scope)
        }
    }
}

// MARK: - The one-time switch to default-off

enum Migration {
    struct Summary: Equatable {
        var allowed: [String]
        var removedBlocks: Int
        var keptBlocks: Int
    }

    /// Everything on today goes on the allowlist, so the day of the switch changes nothing.
    /// Servers defined only in a project are allowed by name: that permits them only
    /// where they already exist. Blocks that match a known server are dropped, since a
    /// project could never undo them. Other blocks stay.
    static func plan(paths: Paths, state: AppState) throws -> (allow: [[String: Any]], deny: [[String: Any]], summary: Summary) {
        let loader = InventoryLoader(paths: paths, state: state)
        let settings = try loader.claudeSettings(scope: .allProjects)
        let inventory = try loader.load(scope: .allProjects)
        let refs: [ClaudeServerRef] = inventory.services.flatMap(\.controls).compactMap {
            if case .claudeServer(let ref) = $0.target { return ref }
            return nil
        }

        var allow: [[String: Any]] = []
        var names: [String] = []
        func add(_ rule: ClaudeRule, _ label: String) {
            guard !allow.contains(where: { NSDictionary(dictionary: $0).isEqual(to: rule.json) }) else { return }
            allow.append(rule.json)
            names.append(label)
        }
        for ref in refs where !settings.deniedByUser(ref) {
            if let rule = ref.allowRule, let label = ref.names.sorted().first { add(rule, label) }
        }

        let claude = try readJSONObject(paths.claudeJson)
        for (path, raw) in claude["projects"] as? [String: [String: Any]] ?? [:] {
            var projectServers = Set((raw["mcpServers"] as? [String: Any] ?? [:]).keys)
            if let json = try? readJSONObject(paths.projectMcp(path)) {
                projectServers.formUnion((json["mcpServers"] as? [String: Any] ?? [:]).keys)
            }
            for name in projectServers.sorted() {
                let ref = ClaudeServerRef(names: [name], urls: [], command: nil, allowableNames: [name], allowRule: .name(name), denyRule: .name(name))
                if !settings.deniedByUser(ref) { add(.name(name), name) }
            }
        }

        let deny = settings.user["deniedMcpServers"] as? [[String: Any]] ?? []
        let kept = deny.filter { entry in
            !refs.contains { ClaudeRules.entry(entry, matches: $0, forAllow: false) }
        }
        return (allow, kept, Summary(allowed: names, removedBlocks: deny.count - kept.count, keptBlocks: kept.count))
    }

    /// Backs up `settings.json` first and returns the backup's path.
    @discardableResult
    static func apply(paths: Paths, state: inout AppState, writer: ConfigWriter, now: Date = Date()) throws -> Summary {
        let result = try plan(paths: paths, state: state)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = paths.backups.appendingPathComponent("settings-\(formatter.string(from: now)).json")
        if writer.readOnly { throw LoadoutError.readOnly("settings.json") }
        try FileManager.default.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: paths.claudeSettings, to: backup)

        try writer.editJSON(paths.claudeSettings) { json in
            json["allowedMcpServers"] = result.allow
            if result.deny.isEmpty {
                json.removeValue(forKey: "deniedMcpServers")
            } else {
                json["deniedMcpServers"] = result.deny
            }
        }
        state.migrationBackup = backup.path
        try state.save(paths)
        return result.summary
    }

    /// Puts only the two lists back from the backup, so any later change to other
    /// settings survives.
    static func restore(paths: Paths, state: inout AppState, writer: ConfigWriter) throws {
        guard let path = state.migrationBackup else { return }
        let backup = try readJSONObject(URL(fileURLWithPath: path))
        try writer.editJSON(paths.claudeSettings) { json in
            for key in ["allowedMcpServers", "deniedMcpServers"] {
                if let value = backup[key] {
                    json[key] = value
                } else {
                    json.removeValue(forKey: key)
                }
            }
        }
        state.migrationBackup = nil
        try state.save(paths)
    }
}
