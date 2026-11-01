import SwiftUI
import AppKit

// MARK: - Scope bar

/// Always says what the switches below will change, in words.
struct ScopeBar: View {
    @ObservedObject var store: AppStore
    @Binding var picking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                picking.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: store.selectedProject == nil ? "square.stack.3d.up" : "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: store.selectedProject?.name ?? "All projects")
                            .font(.rowTitle)
                            .lineLimit(1)
                        if let path = store.selectedProject?.displayPath {
                            Text(verbatim: path)
                                .font(.rowMeta)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: picking ? "chevron.up" : "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.rowPadding)
                .frame(minHeight: 36)
                .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.track))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Project: \(store.selectedProject?.name ?? "All projects")")
            .accessibilityHint("Choose which project the switches change")

            HStack(spacing: 6) {
                Text(verbatim: explanation)
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if store.selectedProject != nil && store.setHereCount > 0 {
                    TwoStepConfirmButton(
                        idleLabel: "Reset all",
                        confirmLabel: "Confirm reset",
                        systemImage: "arrow.uturn.backward",
                        action: { store.resetProject() }
                    )
                }
            }
            .frame(minHeight: 24)
            .padding(.horizontal, Theme.rowPadding)
        }
        .padding(.horizontal, Theme.rowInset)
        .padding(.bottom, 8)
    }

    private var explanation: String {
        guard store.selectedProject != nil else {
            return "The default for every project. A project can differ."
        }
        let count = store.setHereCount
        if count == 0 { return "Only this folder. Everything follows the default." }
        return "Only this folder. \(count) set here, the rest follow the default."
    }
}

// MARK: - Project picker

/// A search field that hands arrow keys, Return and Escape to its owner. A SwiftUI
/// TextField's field editor would keep them, and Escape would close the whole panel.
struct PickerField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PickerField
        init(parent: PickerField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}

struct ProjectPicker: View {
    @ObservedObject var store: AppStore
    let onClose: () -> Void

    @State private var query = ""
    @State private var highlighted = 0

    /// Nil stands for All projects. It's hidden once a search is typed.
    private var options: [KnownProject?] {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        if term.isEmpty { return [nil] + store.projects.map(Optional.some) }
        return store.projects.filter { $0.path.lowercased().contains(term) }.map(Optional.some)
    }

    private func pick(_ option: KnownProject?) {
        store.select(option.map { .project($0.path) } ?? .allProjects)
        onClose()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                PickerField(
                    text: $query,
                    placeholder: "Search \(store.projects.count) projects",
                    onMove: { delta in
                        guard !options.isEmpty else { return }
                        highlighted = min(max(0, highlighted + delta), options.count - 1)
                    },
                    onSubmit: {
                        if options.indices.contains(highlighted) { pick(options[highlighted]) }
                    },
                    onCancel: onClose
                )
                .accessibilityLabel("Search projects")
            }
            .padding(.horizontal, Theme.gutter)
            .frame(height: 34)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if options.isEmpty {
                            EmptyState(symbol: "folder", title: "No project matches", message: "Use Choose folder for one Claude Code hasn't opened.")
                        }
                        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                            ProjectOption(
                                project: option,
                                selected: option?.path == store.scope.projectPath,
                                highlighted: index == highlighted,
                                onPick: { pick(option) }
                            )
                            .id(index)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Button {
                    onClose()
                    store.chooseFolder()
                } label: {
                    Label("Choose folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(CapsuleButtonStyle())
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(CapsuleButtonStyle())
            }
            .padding(.horizontal, Theme.gutter)
            .frame(height: 40)
        }
        .onChange(of: query) { highlighted = 0 }
    }
}

private struct ProjectOption: View {
    let project: KnownProject?
    let selected: Bool
    let highlighted: Bool
    let onPick: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 8) {
                Image(systemName: project == nil ? "square.stack.3d.up" : "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: project?.name ?? "All projects")
                        .font(.rowTitle)
                        .lineLimit(1)
                    Text(verbatim: project?.displayPath ?? "The default every project starts from")
                        .font(.rowMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Selected")
                }
            }
            .padding(.horizontal, Theme.rowPadding)
            .frame(minHeight: 38)
            .background(
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                    .fill(highlighted ? Theme.hoverStrong : (hovering ? Theme.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, Theme.rowInset)
        .accessibilityLabel(project?.name ?? "All projects")
    }
}

// MARK: - Shared pieces

struct FilterField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, Theme.rowPadding)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.track))
        .padding(.horizontal, Theme.rowInset)
        .padding(.top, 8)
    }
}

/// The small "This project" badge, with a way back to the default right next to it.
struct SetHereTag: View {
    var body: some View {
        Text("This project")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(Theme.accent.opacity(0.12)))
            .fixedSize()
    }
}

struct ProjectMarker: View {
    let projects: [String]

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "folder")
                .font(.system(size: 9, weight: .semibold))
            Text(verbatim: "Set in \(projects.count) \(projects.count == 1 ? "project" : "projects")")
                .font(.rowMeta)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .help(projects.joined(separator: ", "))
    }
}

struct InlineNote: View {
    let text: String
    var body: some View {
        Text(verbatim: text)
            .font(.rowSubtitle)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 6)
    }
}

func formatTokens(_ tokens: Int) -> String {
    "~\(tokens.formatted()) tokens"
}

// MARK: - Migration banner

struct MigrationBanner: View {
    @ObservedObject var store: AppStore

    private var waitingText: String? {
        switch store.discovery {
        case .running: return "Checking your claude.ai connectors first…"
        case .failed: return "Couldn't list your claude.ai connectors, so switching now could turn some off. Check that the claude command works, then reload."
        case .done: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Control servers per project")
                .font(.rowTitle)
            Text("Today a server blocked for all projects can't be turned on in just one, and new connectors turn on by themselves. Switch so a server is off unless you allow it. What's on today stays on, and your settings are backed up first.")
                .font(.rowSubtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let waitingText {
                Text(verbatim: waitingText)
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Switch") { store.migrate() }
                    .buttonStyle(CapsuleButtonStyle())
                    .disabled(!store.canMigrate)
                Button("Not now") { store.migrationDismissed = true }
                    .buttonStyle(CapsuleButtonStyle())
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.accent.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.25), lineWidth: 0.5)
        )
        .padding(.horizontal, Theme.rowInset)
        .padding(.top, 8)
    }
}

// MARK: - Tools

struct ToolsSection: View {
    @ObservedObject var store: AppStore
    @State private var filter = ""
    @State private var expanded: Set<String> = []

    private var matches: [Service] {
        let term = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return store.inventory.services }
        return store.inventory.services.filter { $0.name.lowercased().contains(term) }
    }

    private var summary: String {
        let services = store.inventory.services
        let on = services.filter(\.isOn).count
        let tokens = services.filter(\.isOn).reduce(0) { $0 + $1.pluginSkills.filter(\.enabled).reduce(0) { $0 + $1.tokens } }
        var text = "\(on) of \(services.count) on"
        if tokens > 0 { text += " · plugin skills \(formatTokens(tokens))" }
        return text
    }

    var body: some View {
        if store.inventory.needsMigration && !store.migrationDismissed {
            MigrationBanner(store: store)
        }
        if store.inventory.services.isEmpty {
            EmptyState(
                symbol: "puzzlepiece.extension",
                title: "No tools found",
                message: "Plugins, MCP servers and claude.ai connectors show up here."
            )
        } else {
            FilterField(text: $filter, placeholder: "Filter tools")
            ListToolbar(summary: summary)
            if matches.isEmpty {
                EmptyState(symbol: "line.3.horizontal.decrease", title: "Nothing matches \(filter)")
            }
            ForEach(matches) { service in
                ServiceRow(
                    store: store,
                    service: service,
                    expanded: Binding(
                        get: { expanded.contains(service.id) },
                        set: { if $0 { expanded.insert(service.id) } else { expanded.remove(service.id) } }
                    )
                )
            }
        }
    }
}

struct ServiceRow: View {
    @ObservedObject var store: AppStore
    let service: Service
    @Binding var expanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var subtitle: String {
        var parts = [service.kindSummary]
        if service.tokens > 0 { parts.append(formatTokens(service.tokens)) }
        parts.append(service.harnesses.map(\.label).joined(separator: ", "))
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The button's label replaces its contents for VoiceOver, so what the row shows
    /// has to be repeated here or it's lost.
    private var accessibilityDetail: String {
        var parts = [expanded ? "Expanded" : "Collapsed", subtitle]
        if let statusLine { parts.append(statusLine) }
        if service.setHere { parts.append("This project") }
        if !service.setInProjects.isEmpty {
            parts.append("Set in \(service.setInProjects.count) \(service.setInProjects.count == 1 ? "project" : "projects")")
        }
        return parts.joined(separator: ". ")
    }

    private var statusLine: String? {
        service.active.compactMap(\.status).first { $0.lowercased() != "connected" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Tile(
                            glyph: .monogram(Tile.monogram(for: service.name)),
                            tint: Tile.tint(for: service.id),
                            dimmed: !service.isOn
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: service.name)
                                    .font(.rowTitle)
                                    .lineLimit(1)
                                if service.setHere { SetHereTag() }
                                if !service.setInProjects.isEmpty { ProjectMarker(projects: service.setInProjects) }
                            }
                            Text(verbatim: subtitle)
                                .font(.rowSubtitle)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(subtitle)
                            if let statusLine {
                                Text(verbatim: statusLine)
                                    .font(.rowMeta)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(service.name), details")
                .accessibilityValue(accessibilityDetail)

                if service.setHere {
                    IconButton(systemName: "arrow.uturn.backward", help: "Back to the default") {
                        store.reset(service)
                    }
                    .accessibilityLabel("Reset \(service.name) to the default")
                }
                mainControl
            }
            .rowChrome()

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(service.controls) { control in
                        ControlRow(store: store, service: service, control: control)
                    }
                    if !service.pluginSkills.isEmpty {
                        PluginSkillList(service: service)
                    }
                }
                .padding(.leading, Theme.gutter + 34)
                .padding(.trailing, Theme.gutter)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.reveal, value: expanded)
    }

    @ViewBuilder
    private var mainControl: some View {
        switch service.mainState {
        case .locked(let on):
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9.5))
                Text(on ? "On" : "Off")
                    .font(.control)
            }
            .foregroundStyle(.secondary)
            .help(service.firstLockReason ?? "")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(service.name): \(on ? "on" : "off"), locked. \(service.firstLockReason ?? "")")
        case .mixed:
            HStack(spacing: 6) {
                Text("Partly on")
                    .font(.rowMeta)
                    .foregroundStyle(.secondary)
                LoadoutSwitch(label: service.name, isOn: true) { store.setService(service, on: false) }
            }
        case .on:
            LoadoutSwitch(label: service.name, isOn: true) { store.setService(service, on: false) }
        case .off:
            LoadoutSwitch(label: service.name, isOn: false) { store.setService(service, on: true) }
        }
    }
}

/// One tool's view of a service: its own switch, why it's locked, or how to add it.
struct ControlRow: View {
    @ObservedObject var store: AppStore
    let service: Service
    let control: Control

    private var title: String { "\(control.harness.label): \(control.label)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(.rowSubtitle)
                        .lineLimit(1)
                    if let detail = control.definition?.summary, !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.rowMeta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(detail)
                    }
                    if let status = control.status {
                        Text(verbatim: status)
                            .font(.rowMeta)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                trailing
            }
            if let lock = control.lock {
                Text(verbatim: lock.reason)
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = lock.fix { fixButton(fix) }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if control.lock != nil {
            Image(systemName: "lock.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Locked")
        } else if !control.setUp {
            Button("Add to this project") { store.set(control, in: service, on: true) }
                .buttonStyle(CapsuleButtonStyle())
        } else {
            LoadoutSwitch(label: "\(service.name) in \(control.harness.label)", isOn: control.on) {
                store.set(control, in: service, on: !control.on)
            }
        }
    }

    @ViewBuilder
    private func fixButton(_ fix: ControlLock.Fix) -> some View {
        switch fix {
        case .trustCodex:
            Button("Trust this folder in Codex") { store.trustCodex() }
                .buttonStyle(CapsuleButtonStyle())
        case .switchToPerProject:
            Button("Switch to per-project control") { store.migrate() }
                .buttonStyle(CapsuleButtonStyle())
                .disabled(!store.canMigrate)
        }
    }
}

private struct PluginSkillList: View {
    let service: Service

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "\(service.pluginSkills.count) skills come with this plugin. They go on and off with it.")
                .font(.rowSubtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(service.pluginSkills) { skill in
                HStack {
                    Text(verbatim: skill.name)
                        .font(.rowSubtitle)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(verbatim: formatTokens(skill.tokens))
                        .font(.rowMeta)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Skills

struct SkillsSection: View {
    @ObservedObject var store: AppStore
    var onOpenTools: () -> Void = {}

    @State private var filter = ""

    private var skills: [SkillItem] { store.inventory.skills }

    private var matches: [SkillItem] {
        let term = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return skills }
        return skills.filter { $0.key.lowercased().contains(term) }
    }

    private var pluginServices: [Service] {
        store.inventory.services.filter { !$0.pluginSkills.isEmpty }
    }

    private var summary: String {
        "\(skills.filter { $0.state == .on }.count) of \(skills.count) on Auto · \(formatTokens(store.inventory.skillTokens)) every session"
    }

    var body: some View {
        if skills.isEmpty && pluginServices.isEmpty {
            EmptyState(
                symbol: "sparkles",
                title: "No skills found",
                message: "Skills live in ~/.claude/skills or inside installed plugins."
            )
        } else {
            FilterField(text: $filter, placeholder: "Filter skills")
            ListToolbar(summary: summary) {
                if !skills.isEmpty {
                    TwoStepConfirmButton(
                        idleLabel: "Turn all off",
                        confirmLabel: "Confirm",
                        systemImage: "power",
                        action: { store.turnOffAllSkills() }
                    )
                }
            }
            SkillLegend()
            if !store.inventory.deadOverrideKeys.isEmpty {
                let count = store.inventory.deadOverrideKeys.count
                HStack(spacing: 8) {
                    Text(verbatim: "\(count) old plugin skill \(count == 1 ? "setting does" : "settings do") nothing. Claude Code ignores them.")
                        .font(.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Remove") { store.removeDeadOverrides() }
                        .buttonStyle(CapsuleButtonStyle())
                }
                .padding(.leading, Theme.gutter)
                .padding(.trailing, Theme.rowInset + 4)
                .padding(.top, 6)
            }
            if !skills.isEmpty {
                SectionLabel(title: "Your skills", count: skills.count)
                ForEach(matches) { skill in
                    SkillRow(store: store, skill: skill)
                }
            }
            if !pluginServices.isEmpty {
                SectionLabel(title: "From plugins", count: pluginServices.count)
                ForEach(pluginServices) { service in
                    PluginSkillSummaryRow(service: service, onOpenTools: onOpenTools)
                }
            }
        }
    }
}

/// Always on screen, so the three words never need a hover to decode.
struct SkillLegend: View {
    private let items: [(String, String)] = [
        ("Auto", "the agent can pick it"),
        ("Manual", "only when you type /name"),
        ("Off", "hidden everywhere"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(items, id: \.0) { item in
                (Text(verbatim: item.0).fontWeight(.medium).foregroundColor(.primary)
                 + Text(verbatim: " \(item.1)").foregroundColor(.secondary))
                    .font(.rowSubtitle)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 2)
    }
}

struct SkillRow: View {
    @ObservedObject var store: AppStore
    let skill: SkillItem

    private var allowed: Set<SkillOverride> {
        skill.lock == .author ? [.userInvocableOnly, .off] : [.on, .userInvocableOnly, .off, .nameOnly]
    }

    private var subtitle: String {
        var parts: [String] = []
        if skill.source == .project { parts.append("In this repo") }
        if skill.lock == .author {
            parts.append("Its author turned off Auto")
        } else if skill.state == .on {
            parts.append(formatTokens(skill.tokens))
        } else if skill.state == .nameOnly {
            parts.append("Name only")
        } else {
            parts.append("Saves \(formatTokens(skill.tokens))")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: skill.key)
                        .font(.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(skill.key)
                    if skill.setHere { SetHereTag() }
                }
                HStack(spacing: 6) {
                    Text(verbatim: subtitle)
                        .font(.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !skill.projects.isEmpty {
                        ProjectMarker(projects: skill.projects.map { "\($0.project): \($0.state.label)" })
                    }
                }
            }
            Spacer(minLength: 6)
            if skill.setHere {
                IconButton(systemName: "arrow.uturn.backward", help: "Back to the default") {
                    store.resetSkill(skill)
                }
                .accessibilityLabel("Reset \(skill.key) to the default")
            }
            SkillStateSegments(name: skill.key, current: skill.state, allowed: allowed) {
                store.setSkill(skill, to: $0)
            }
        }
        .rowChrome()
        .contextMenu {
            if skill.lock == nil {
                Button("Name only: the agent sees just the name") { store.setSkill(skill, to: .nameOnly) }
            }
        }
    }
}

/// Auto, Manual, Off, all visible and one click away. Name only joins them only when
/// it's already the state; it's in the row's context menu otherwise.
struct SkillStateSegments: View {
    let name: String
    let current: SkillOverride
    let allowed: Set<SkillOverride>
    let onPick: (SkillOverride) -> Void

    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: [SkillOverride] {
        current == .nameOnly ? [.on, .nameOnly, .userInvocableOnly, .off] : [.on, .userInvocableOnly, .off]
    }

    private func shortLabel(_ state: SkillOverride) -> String {
        state == .nameOnly ? "Name" : state.label
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(shown) { state in
                let selected = state == current
                let enabled = allowed.contains(state)
                Button {
                    onPick(state)
                } label: {
                    Text(verbatim: shortLabel(state))
                        .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? (state == .on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)) : AnyShapeStyle(enabled ? .secondary : .quaternary))
                        .lineLimit(1)
                        .frame(width: 46, height: 20)
                        .background {
                            if selected {
                                // Only Auto earns the accent. Every reduced state stays neutral.
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
                .help(enabled ? state.explanation : "Its author turned off Auto, so it can only be Manual or Off.")
                .accessibilityLabel("\(name): \(state.label)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.track))
        .animation(reduceMotion ? nil : Motion.slide, value: current)
    }
}

private struct PluginSkillSummaryRow: View {
    let service: Service
    let onOpenTools: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: service.name)
                    .font(.rowTitle)
                    .lineLimit(1)
                Text(verbatim: "\(service.pluginSkills.count) skills · \(service.isOn ? formatTokens(service.tokens) : "Off, saves \(formatTokens(service.tokens))")")
                    .font(.rowSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("Change in Tools", action: onOpenTools)
                .buttonStyle(CapsuleButtonStyle())
        }
        .rowChrome()
    }
}
