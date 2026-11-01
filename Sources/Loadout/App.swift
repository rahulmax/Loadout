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
                .foregroundStyle(.secondary)
            if let count {
                Text(verbatim: "\(count)").foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
    /// Read out by VoiceOver. The label is hidden visually: the row already shows it.
    let label: String
    let isOn: Bool
    let onToggle: () -> Void
    var body: some View {
        Toggle(label, isOn: Binding(get: { isOn }, set: { _ in onToggle() }))
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
    @State private var picking = false
    @State private var namingPreset = false
    @State private var presetName = ""
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
        case tools = "Tools"
        case skills = "Skills"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .ports: return "dot.radiowaves.left.and.right"
            case .tools: return "puzzlepiece.extension"
            case .skills: return "sparkles"
            }
        }
    }

    private func count(for tab: Tab) -> Int {
        switch tab {
        case .ports: return portsStore.ports.count
        case .tools: return store.inventory.services.count
        case .skills: return store.inventory.skills.count
        }
    }

    private var knownProjectPaths: [String] {
        var paths = store.projects.map(\.path)
        if let selected = store.scope.projectPath, !paths.contains(selected) { paths.append(selected) }
        return paths
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScopeBar(store: store, picking: $picking)

            if picking {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ProjectPicker(store: store, onClose: { picking = false })
                    .frame(maxHeight: .infinity)
            } else {
                if namingPreset { presetNameRow }

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
                        case .ports:
                            PortsSection(
                                store: portsStore,
                                knownProjects: knownProjectPaths,
                                selectedProject: store.scope.projectPath,
                                onOpenProject: { path in
                                    store.select(.project(path))
                                    tab = .tools
                                }
                            )
                        case .tools:
                            ToolsSection(store: store)
                        case .skills:
                            SkillsSection(store: store, onOpenTools: { tab = .tools })
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.automatic)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
        }
        .frame(
            width: 440,
            height: fixedHeight ?? min(1100, (NSScreen.main?.visibleFrame.height ?? 1000) - 80)
        )
        .onAppear { portsStore.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            store.panelOpened()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            BrandMark()
            Text("Loadout").font(.panelTitle)
            Spacer()
            optionsMenu
            IconButton(
                systemName: "arrow.clockwise",
                help: "Reload from disk",
                rotation: .degrees(Double(refreshSpins) * 360)
            ) {
                if !reduceMotion {
                    withAnimation(.timingCurve(0.77, 0, 0.175, 1, duration: 0.6)) { refreshSpins += 1 }
                }
                store.reload()
                store.refreshConnectors()
                portsStore.refresh()
            }
            .accessibilityLabel("Reload from disk")
        }
        .padding(.leading, Theme.gutter)
        .padding(.trailing, Theme.rowInset + 2)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var optionsMenu: some View {
        Menu {
            Section("Tools to manage") {
                ForEach(Harness.allCases) { harness in
                    Toggle(harness.label, isOn: Binding(
                        get: { store.managedHarnesses.contains(harness) },
                        set: { store.setManaged(harness, $0) }
                    ))
                    .disabled(harness == .claude)
                }
            }
            Section("Presets") {
                ForEach(store.state.presets) { preset in
                    Menu(preset.name) {
                        Button("Apply to \(store.selectedProject?.name ?? "all projects")") { store.apply(preset) }
                        Button("Delete") { store.deletePreset(preset) }
                    }
                }
                Button("Save current as preset…") {
                    picking = false
                    presetName = ""
                    namingPreset = true
                }
            }
            if store.inventory.needsMigration {
                Button("Switch to per-project control") { store.migrate() }
                    .disabled(!store.canMigrate)
            }
            if store.state.migrationBackup != nil {
                Button("Restore settings from before the switch") { store.restoreBeforeMigration() }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Tools, presets and restore")
        .accessibilityLabel("Options")
    }

    private var presetNameRow: some View {
        HStack(spacing: 8) {
            TextField("Preset name", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit(savePreset)
            Button("Save", action: savePreset)
                .buttonStyle(CapsuleButtonStyle())
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { namingPreset = false }
                .buttonStyle(CapsuleButtonStyle())
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 10)
    }

    private func savePreset() {
        store.savePreset(named: presetName)
        namingPreset = false
    }

    private var footer: some View {
        HStack(spacing: 7) {
            ZStack {
                if store.note != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.iconSwap)
                } else {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(.secondary)
                        .transition(.iconSwap)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .frame(width: 14)

            ZStack(alignment: .leading) {
                if let note = store.note {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: note.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(note.text)
                        if note.copiedReload {
                            HStack(spacing: 4) {
                                Text("Copied")
                                CodeChip(text: "/reload-plugins")
                                Text("for open Claude sessions")
                            }
                            .help("Paste it into an open Claude Code session. Other tools and new sessions pick the change up when they start.")
                        }
                    }
                    .id(note.id)
                    .transition(.textSwap)
                } else {
                    HStack(spacing: 4) {
                        Text("Open Claude sessions need")
                        CodeChip(text: "/reload-plugins")
                    }
                    .help("Each change copies the command. Other tools and new sessions pick the change up when they start.")
                    .transition(.textSwap)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            if store.canUndo {
                Button("Undo") { store.undo() }
                    .buttonStyle(CapsuleButtonStyle())
                    .keyboardShortcut("z")
            }
            QuitButton()
        }
        .animation(reduceMotion ? nil : Motion.reveal, value: store.note)
        .padding(.leading, Theme.gutter)
        .padding(.trailing, Theme.rowInset + 2)
        .frame(height: 44)
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
                            .foregroundStyle(.secondary)
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
                .accessibilityLabel(item.rawValue)
                .accessibilityValue("\(count(item))")
                .accessibilityAddTraits(selected ? .isSelected : [])
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
                Text("⌘Q").foregroundStyle(.secondary)
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

// MARK: - Debug snapshots

#if DEBUG
/// `LOADOUT_SNAPSHOT=/some/dir .build/debug/Loadout` renders every tab in light and
/// dark into PNGs, then exits. `LOADOUT_SCOPE=/a/project` renders that project's view.
/// Lets you review the panel without clicking through the menu bar. Debug builds only.
enum SnapshotRenderer {
    @MainActor private static var windows: [NSWindow] = []

    @MainActor static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["LOADOUT_SNAPSHOT"] else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let outDir = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let scope = ProcessInfo.processInfo.environment["LOADOUT_SCOPE"].map(Scope.project)
        let store = AppStore(readOnly: true, initialScope: scope ?? .allProjects)
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
