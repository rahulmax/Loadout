import SwiftUI
import AppKit

/// Holds what the panel shows. On/off choices are never kept here: every reload reads
/// them back from each tool's own files, so an edit made elsewhere shows up as it is.
@MainActor
final class AppStore: ObservableObject {
    enum Discovery: Equatable {
        case running, done, failed
    }

    struct Note: Equatable {
        let id = UUID()
        let text: String
        /// True when `/reload-plugins` is on the clipboard for the user to paste.
        var copiedReload = true
    }

    private struct UndoEntry {
        let change: ConfigWriter.Change
        let stateBefore: AppState
        let message: String
    }

    @Published private(set) var scope: Scope = .allProjects
    @Published private(set) var inventory = Inventory()
    /// Real projects, for the picker.
    @Published private(set) var projects: [KnownProject] = []
    /// Every folder the tools have opened, so a running server still finds its group.
    @Published private(set) var allFolders: [String] = []
    @Published private(set) var note: Note?
    @Published private(set) var discovery: Discovery = .running
    @Published private(set) var canUndo = false
    @Published var lastError: String?
    @Published var migrationDismissed = false

    let paths: Paths
    private let writer: ConfigWriter
    private let engine: Engine
    private var undoStack: [UndoEntry] = []
    private var lastDiscovery: Date?
    private let readOnly: Bool
    private var catalogLoading = false
    private var catalogStale = false

    private static let projectCap = 200
    /// `claude mcp list` health-checks every server, so it isn't run on every open.
    private static let discoveryInterval: TimeInterval = 300

    init(readOnly: Bool = false, home: URL? = nil, initialScope: Scope? = nil) {
        self.readOnly = readOnly
        paths = Paths(home: home ?? Self.defaultHome)
        writer = ConfigWriter(readOnly: readOnly)
        engine = Engine(paths: paths, state: AppState.load(paths), writer: writer)
        if !readOnly { cleanUpOldVersions() }
        if let initialScope {
            scope = initialScope
        } else if let saved = engine.state.selectedProject, FileManager.default.fileExists(atPath: saved) {
            scope = .project(saved)
        }
        reload()
        refreshConnectors()
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

    private func cleanUpOldVersions() {
        do {
            try engine.restoreParkedServers()
        } catch {
            lastError = "Could not tidy older Loadout settings: \(error.localizedDescription)"
        }
        _ = writer.finishChange()
    }

    // MARK: Reading

    var state: AppState { engine.state }

    var selectedProject: KnownProject? {
        guard let path = scope.projectPath else { return nil }
        return projects.first { $0.path == path } ?? KnownProject(path: path, lastUsed: nil)
    }

    /// How many things this project sets for itself.
    var setHereCount: Int {
        inventory.services.filter(\.setHere).count + inventory.skills.filter(\.setHere).count
    }

    var managedHarnesses: [Harness] {
        Harness.allCases.filter { engine.state.manages($0, paths: paths) }
    }

    /// The tools worth offering: installed, or already turned on.
    var availableHarnesses: [Harness] {
        Harness.allCases.filter { engine.state.isInstalled($0, paths: paths) || managedHarnesses.contains($0) }
    }

    func reload() {
        do {
            let loader = InventoryLoader(paths: paths, state: engine.state)
            inventory = try loader.load(scope: scope)
            lastError = nil
        } catch {
            lastError = "Could not read settings: \(error.localizedDescription)"
        }
        loadProjects()
    }

    /// The list touches every folder in the tools' history, any of which can be slow or
    /// protected, so it never runs on the main thread. Snapshots stay synchronous.
    private func loadProjects() {
        if readOnly {
            applyCatalog(ProjectCatalog.load(paths, state: engine.state))
            return
        }
        guard !catalogLoading else {
            catalogStale = true
            return
        }
        catalogLoading = true
        let paths = paths
        let state = engine.state
        Task.detached(priority: .userInitiated) {
            let found = ProjectCatalog.load(paths, state: state)
            await MainActor.run { self.finishLoadingProjects(found) }
        }
    }

    private func applyCatalog(_ found: [KnownProject]) {
        projects = Array(found.filter(\.isProject).prefix(Self.projectCap))
        allFolders = found.map(\.path)
    }

    private func finishLoadingProjects(_ found: [KnownProject]) {
        applyCatalog(found)
        catalogLoading = false
        if catalogStale {
            catalogStale = false
            loadProjects()
        }
    }

    /// Runs when the panel opens, so edits made elsewhere are never stale on screen.
    func panelOpened() {
        reload()
        if let last = lastDiscovery, Date().timeIntervalSince(last) > Self.discoveryInterval {
            refreshConnectors()
        }
    }

    func refreshConnectors() {
        guard discovery != .running || lastDiscovery == nil else { return }
        discovery = .running
        lastDiscovery = Date()
        let paths = paths
        Task.detached(priority: .utility) {
            let found = discoverConnectors(paths)
            await MainActor.run { self.finishDiscovery(found) }
        }
    }

    private func finishDiscovery(_ found: [ParsedMcpEntry]?) {
        guard let found else {
            discovery = .failed
            return
        }
        discovery = .done
        engine.state.connectorStatus = [:]
        for entry in found {
            engine.state.connectors[entry.name] = entry.url
            engine.state.connectorStatus[entry.name] = entry.status
        }
        saveState()
        reload()
    }

    private func saveState() {
        guard !readOnly else { return }
        do {
            try engine.state.save(paths)
        } catch {
            lastError = "Could not save Loadout's state: \(error.localizedDescription)"
        }
    }

    // MARK: Scope

    func select(_ newScope: Scope) {
        scope = newScope
        engine.state.selectedProject = newScope.projectPath
        if let path = newScope.projectPath,
           !projects.contains(where: { $0.path == path }),
           !engine.state.extraProjects.contains(path) {
            engine.state.extraProjects.append(path)
        }
        saveState()
        reload()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick a project folder"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            select(.project(canonicalPath(url.path)))
        }
    }

    // MARK: Changing things

    /// One user action: everything `work` writes undoes together, and a failure part
    /// way through puts back whatever had already been written.
    private func perform(_ message: String, copyReload: Bool = true, _ work: () throws -> Void) {
        let before = engine.state
        do {
            try work()
            let change = writer.finishChange()
            if !change.isEmpty {
                undoStack.append(UndoEntry(change: change, stateBefore: before, message: message))
                canUndo = true
            }
            lastError = nil
            if copyReload {
                let board = NSPasteboard.general
                board.clearContents()
                board.setString("/reload-plugins", forType: .string)
            }
            note = Note(text: message, copiedReload: copyReload)
        } catch {
            let partial = writer.finishChange()
            try? writer.undo(partial)
            engine.state = before
            saveState()
            reload()
            lastError = error.localizedDescription
            return
        }
        reload()
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        canUndo = !undoStack.isEmpty
        do {
            try writer.undo(entry.change)
            _ = writer.finishChange()
            engine.state = entry.stateBefore
            saveState()
            note = Note(text: "Undid: \(entry.message)", copiedReload: false)
            reload()
        } catch {
            _ = writer.finishChange()
            lastError = error.localizedDescription
        }
    }

    private var whereText: String {
        guard let project = selectedProject else { return "by default" }
        return "in \(project.name)"
    }

    func setService(_ service: Service, on: Bool) {
        perform("\(service.name) \(on ? "on" : "off") \(whereText)") {
            try engine.setService(service, on: on, scope: scope)
        }
    }

    func set(_ control: Control, in service: Service, on: Bool) {
        perform("\(service.name) \(on ? "on" : "off") in \(control.harness.label) \(whereText)") {
            try engine.set(control, on: on, scope: scope)
        }
    }

    func reset(_ service: Service) {
        perform("\(service.name) back to the default") {
            try engine.resetService(service, scope: scope)
        }
    }

    func setSkill(_ skill: SkillItem, to value: SkillOverride) {
        perform("\(skill.key) \(value.label) \(whereText)") {
            try engine.setSkill(skill, to: value, scope: scope)
        }
    }

    func resetSkill(_ skill: SkillItem) {
        guard let project = scope.projectPath else { return }
        perform("\(skill.key) back to the default") {
            try engine.resetSkill(skill, project: project)
        }
    }

    func turnOffAllSkills() {
        perform("All skills off \(whereText)") {
            try engine.setSkills(inventory.skills, to: .off, scope: scope)
        }
    }

    func removeDeadOverrides() {
        let keys = inventory.deadOverrideKeys
        perform("Removed \(keys.count) old skill settings", copyReload: false) {
            try engine.removeDeadOverrides(keys)
        }
    }

    func resetProject() {
        guard let project = selectedProject else { return }
        perform("\(project.name) back to the defaults") {
            try engine.resetProject(project.path, inventory: inventory)
        }
    }

    func trustCodex() {
        guard let project = selectedProject else { return }
        perform("\(project.name) trusted in Codex", copyReload: false) {
            try engine.trustCodex(project: project.path)
        }
    }

    func setManaged(_ harness: Harness, _ on: Bool) {
        // With nothing shown the panel would be empty and look broken.
        guard on || managedHarnesses != [harness] else { return }
        engine.state.harnesses[harness.rawValue] = on
        saveState()
        reload()
    }

    // MARK: The switch to default-off

    /// Switching needs the full list of connectors. Without it, one that's on today
    /// would miss the allowlist and quietly go off.
    var canMigrate: Bool { discovery == .done }

    func migrate() {
        guard canMigrate else { return }
        var summary: Migration.Summary?
        perform("Switched to per-project control", copyReload: false) {
            summary = try Migration.apply(paths: paths, state: &engine.state, writer: writer)
        }
        if let summary {
            let count = summary.allowed.count
            note = Note(
                text: "Switched. \(count) \(count == 1 ? "server stays" : "servers stay") on, the rest are off. Settings backed up.",
                copiedReload: false
            )
        }
    }

    func restoreBeforeMigration() {
        perform("Restored settings from before the switch", copyReload: false) {
            try Migration.restore(paths: paths, state: &engine.state, writer: writer)
        }
    }

    // MARK: Presets

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = engine.snapshotPreset(name: trimmed, inventory: inventory)
        engine.state.presets.removeAll { $0.name == trimmed }
        engine.state.presets.append(preset)
        engine.state.presets.sort { $0.name.lowercased() < $1.name.lowercased() }
        saveState()
        note = Note(text: "Saved preset \(trimmed)", copiedReload: false)
        objectWillChange.send()
    }

    func deletePreset(_ preset: Preset) {
        engine.state.presets.removeAll { $0.name == preset.name }
        saveState()
        objectWillChange.send()
    }

    func apply(_ preset: Preset) {
        perform("Preset \(preset.name) applied \(whereText)") {
            try engine.apply(preset, scope: scope, inventory: inventory)
        }
    }
}
