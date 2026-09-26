import SwiftUI
import AppKit
import Darwin
import Network

// Ports tab: local dev server discovery, health probing, kill and restart.
// Detection logic ported from https://github.com/LarsenCundric/port-whisperer
// (lsof for listening sockets + ps/lsof for process metadata + framework
// sniffing from package.json / config files). Health probing (HTTP/TCP) and
// restart are new — the reference CLI doesn't do either.

// MARK: - Models

struct PortEntry: Identifiable, Hashable {
    var id: Int { port }
    let port: Int
    let pid: pid_t
    let processName: String
    let command: String
    let cwd: String?
    let projectName: String?
    let framework: String?
    let uptime: String?
    let isZombie: Bool
    let isOrphaned: Bool

    var url: URL? { URL(string: "http://localhost:\(port)") }
    var canRestart: Bool { cwd != nil && !command.trimmingCharacters(in: .whitespaces).isEmpty }
}

enum PortHealth: Equatable {
    case unknown
    case checking
    case healthy
    case unhealthy
}

// MARK: - Scanner (runs off the main actor)

enum PortScanner {
    struct PSInfo {
        let ppid: pid_t
        let stat: String
        let lstart: String
        let command: String
    }

    /// Full scan: listening TCP sockets -> enriched, filtered, sorted rows.
    static func scan() -> [PortEntry] {
        let raw = listeningSockets()
        guard !raw.isEmpty else { return [] }

        let pids = Array(Set(raw.map { $0.pid }))
        let psMap = batchPS(pids: pids)
        let cwdMap = batchCwd(pids: pids)

        let entries: [PortEntry] = raw.map { socket in
            let ps = psMap[socket.pid]
            let command = ps?.command ?? ""
            let cwd = cwdMap[socket.pid]
            var projectName: String?
            var framework: String?
            var resolvedCwd: String?

            if let cwd, !cwd.isEmpty {
                let root = findProjectRoot(cwd)
                resolvedCwd = root
                projectName = (root as NSString).lastPathComponent
                framework = detectFramework(projectRoot: root)
            }
            if framework == nil {
                framework = detectFrameworkFromCommand(command, socket.processName)
            }

            let isZombie = ps?.stat.contains("Z") ?? false
            let isOrphaned = (ps?.ppid == 1) && isDevProcess(processName: socket.processName, command: command)
            let uptime = ps.flatMap { uptimeString(fromLstart: $0.lstart) }

            return PortEntry(
                port: socket.port,
                pid: socket.pid,
                processName: socket.processName,
                command: command,
                cwd: resolvedCwd,
                projectName: projectName,
                framework: framework,
                uptime: uptime,
                isZombie: isZombie,
                isOrphaned: isOrphaned
            )
        }

        return entries
            .filter { isDevProcess(processName: $0.processName, command: $0.command) }
            .sorted { $0.port < $1.port }
    }

    // MARK: lsof / ps

    private struct RawSocket { let port: Int; let pid: pid_t; let processName: String }

    private static func listeningSockets() -> [RawSocket] {
        let raw = runShell("lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null")
        guard !raw.isEmpty else { return [] }

        var seenPorts: Set<Int> = []
        var result: [RawSocket] = []
        let lines = raw.split(separator: "\n").dropFirst() // drop header
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9 else { continue }
            let processName = parts[0]
            guard let pid = pid_t(parts[1]) else { continue }
            let nameField = parts[8]
            guard let colonIdx = nameField.lastIndex(of: ":") else { continue }
            let portString = nameField[nameField.index(after: colonIdx)...]
            guard let port = Int(portString) else { continue }
            if seenPorts.contains(port) { continue }
            seenPorts.insert(port)
            result.append(RawSocket(port: port, pid: pid, processName: processName))
        }
        return result
    }

    private static func batchPS(pids: [pid_t]) -> [pid_t: PSInfo] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let raw = runShell("ps -p \(list) -o pid=,ppid=,stat=,lstart=,command= 2>/dev/null")
        guard !raw.isEmpty else { return [:] }

        // Groups: 1 pid, 2 ppid, 3 stat, (skip weekday), 4 "Mon D HH:MM:SS YYYY", 5 command
        guard let regex = try? NSRegularExpression(
            pattern: #"^(\d+)\s+(\d+)\s+(\S+)\s+\w+\s+(\w+\s+\d+\s+[\d:]+\s+\d+)\s+(.*)$"#
        ) else { return [:] }

        var map: [pid_t: PSInfo] = [:]
        for line in raw.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            let full = NSRange(s.startIndex..., in: s)
            guard let m = regex.firstMatch(in: s, range: full) else { continue }
            func group(_ i: Int) -> String {
                guard let r = Range(m.range(at: i), in: s) else { return "" }
                return String(s[r])
            }
            guard let pid = pid_t(group(1)), let ppid = pid_t(group(2)) else { continue }
            map[pid] = PSInfo(ppid: ppid, stat: group(3), lstart: group(4), command: group(5))
        }
        return map
    }

    private static func batchCwd(pids: [pid_t]) -> [pid_t: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let raw = runShell("lsof -a -d cwd -p \(list) 2>/dev/null")
        guard !raw.isEmpty else { return [:] }

        var map: [pid_t: String] = [:]
        let lines = raw.split(separator: "\n").dropFirst()
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9, let pid = pid_t(parts[1]) else { continue }
            let path = parts[8...].joined(separator: " ")
            if path.hasPrefix("/") { map[pid] = path }
        }
        return map
    }

    private static func uptimeString(fromLstart raw: String) -> String? {
        let collapsed = raw.split(separator: " ").joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm:ss yyyy"
        guard let start = formatter.date(from: collapsed) else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        if minutes > 0 { return "\(minutes)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    // MARK: Dev-process filter (ported from port-whisperer's isDevProcess)

    private static let systemAppPrefixes: [String] = [
        "spotify", "raycast", "tableplus", "postman", "linear", "cursor", "controlce",
        "rapportd", "superhuma", "setappage", "slack", "discord", "firefox", "chrome",
        "google", "safari", "figma", "notion", "zoom", "teams", "code", "iterm2", "warp",
        "arc", "loginwindow", "windowserver", "systemuise", "kernel_task", "launchd",
        "mdworker", "mds_stores", "cfprefsd", "coreaudio", "corebrightne", "airportd",
        "bluetoothd", "sharingd", "usernoted", "notificationc", "cloudd",
    ]

    private static let devNames: Set<String> = [
        "node", "python", "python3", "ruby", "java", "go", "cargo", "deno", "bun", "php",
        "uvicorn", "gunicorn", "flask", "rails", "npm", "npx", "yarn", "pnpm", "tsc",
        "tsx", "esbuild", "rollup", "turbo", "nx", "jest", "vitest", "mocha", "pytest",
        "cypress", "playwright", "rustc", "dotnet", "gradle", "mvn", "mix", "elixir",
    ]

    private static let cmdIndicatorPatterns: [String] = [
        #"\bnode\b"#, #"\bnext[\s-]"#, #"\bvite\b"#, #"\bnuxt\b"#, #"\bwebpack\b"#,
        #"\bremix\b"#, #"\bastro\b"#, #"\bgulp\b"#, #"\bng serve\b"#, #"\bgatsb"#,
        #"\bflask\b"#, #"\bdjango\b|manage\.py"#, #"\buvicorn\b"#, #"\brails\b"#, #"\bcargo\b"#,
    ]

    static func isDevProcess(processName: String, command: String) -> Bool {
        let name = processName.lowercased()
        let cmd = command.lowercased()

        for prefix in systemAppPrefixes where name.hasPrefix(prefix) { return false }
        if devNames.contains(name) { return true }
        if name.hasPrefix("com.docke") || name == "docker" || name == "docker-sandbox" { return true }

        for pattern in cmdIndicatorPatterns {
            if cmd.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    // MARK: Project root + framework detection

    private static func findProjectRoot(_ dir: String) -> String {
        let markers = ["package.json", "Cargo.toml", "go.mod", "pyproject.toml", "Gemfile", "pom.xml", "build.gradle"]
        var current = dir
        var depth = 0
        let fm = FileManager.default
        while current != "/" && depth < 15 {
            for marker in markers {
                if fm.fileExists(atPath: (current as NSString).appendingPathComponent(marker)) {
                    return current
                }
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
            depth += 1
        }
        return dir
    }

    private static func detectFramework(projectRoot: String) -> String? {
        let fm = FileManager.default
        let pkgPath = (projectRoot as NSString).appendingPathComponent("package.json")
        if fm.fileExists(atPath: pkgPath),
           let data = fm.contents(atPath: pkgPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var deps: [String: Any] = [:]
            if let d = json["dependencies"] as? [String: Any] { deps.merge(d) { a, _ in a } }
            if let d = json["devDependencies"] as? [String: Any] { deps.merge(d) { a, _ in a } }

            let table: [(String, String)] = [
                ("next", "Next.js"), ("nuxt3", "Nuxt"), ("nuxt", "Nuxt"),
                ("@sveltejs/kit", "SvelteKit"), ("svelte", "Svelte"),
                ("@remix-run/react", "Remix"), ("remix", "Remix"), ("astro", "Astro"),
                ("vite", "Vite"), ("@angular/core", "Angular"), ("vue", "Vue"),
                ("react", "React"), ("express", "Express"), ("fastify", "Fastify"),
                ("hono", "Hono"), ("koa", "Koa"), ("@nestjs/core", "NestJS"), ("nestjs", "NestJS"),
                ("gatsby", "Gatsby"), ("webpack-dev-server", "Webpack"),
                ("esbuild", "esbuild"), ("parcel", "Parcel"),
            ]
            for (key, label) in table where deps[key] != nil { return label }
        }

        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: (projectRoot as NSString).appendingPathComponent(name))
        }
        if exists("vite.config.ts") || exists("vite.config.js") { return "Vite" }
        if exists("next.config.js") || exists("next.config.mjs") { return "Next.js" }
        if exists("angular.json") { return "Angular" }
        if exists("Cargo.toml") { return "Rust" }
        if exists("go.mod") { return "Go" }
        if exists("manage.py") { return "Django" }
        if exists("Gemfile") { return "Ruby" }
        return nil
    }

    private static func detectFrameworkFromCommand(_ command: String, _ processName: String) -> String? {
        guard !command.isEmpty else { return detectFrameworkFromName(processName) }
        let cmd = command.lowercased()
        if cmd.contains("next") { return "Next.js" }
        if cmd.contains("vite") { return "Vite" }
        if cmd.contains("nuxt") { return "Nuxt" }
        if cmd.contains("angular") || cmd.contains("ng serve") { return "Angular" }
        if cmd.contains("webpack") { return "Webpack" }
        if cmd.contains("remix") { return "Remix" }
        if cmd.contains("astro") { return "Astro" }
        if cmd.contains("gatsby") { return "Gatsby" }
        if cmd.contains("flask") { return "Flask" }
        if cmd.contains("django") || cmd.contains("manage.py") { return "Django" }
        if cmd.contains("uvicorn") { return "FastAPI" }
        if cmd.contains("rails") { return "Rails" }
        if cmd.contains("cargo") || cmd.contains("rustc") { return "Rust" }
        return detectFrameworkFromName(processName)
    }

    private static func detectFrameworkFromName(_ processName: String) -> String? {
        switch processName.lowercased() {
        case "node": return "Node.js"
        case "python", "python3": return "Python"
        case "ruby": return "Ruby"
        case "java": return "Java"
        case "go": return "Go"
        default: return nil
        }
    }
}

/// Runs a shell command synchronously and returns stdout. Not @MainActor-isolated
/// so it's safe to call from a detached task.
private func runShell(_ command: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", command]
    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = Pipe()
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        return ""
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - Health probing

enum HealthChecker {
    /// HTTP GET with a short timeout; falls back to a raw TCP connect for
    /// non-HTTP services (databases, etc). Never touches the main actor.
    static func check(port: Int) async -> PortHealth {
        if let url = URL(string: "http://127.0.0.1:\(port)/") {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 1.5
            config.timeoutIntervalForResource = 1.5
            let session = URLSession(configuration: config)
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.5
            request.httpMethod = "GET"
            do {
                _ = try await session.data(for: request)
                return .healthy
            } catch {
                // Connection actively refused means nothing is really there anymore.
                if let urlError = error as? URLError, urlError.code == .cannotConnectToHost {
                    return .unhealthy
                }
                // Otherwise (non-HTTP payload, timeout, reset mid-handshake) probe raw TCP.
                return await tcpConnect(port: port)
            }
        }
        return await tcpConnect(port: port)
    }

    private static func tcpConnect(port: Int) async -> PortHealth {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return .unknown }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
            var resumed = false
            let finish: (PortHealth) -> Void = { health in
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: health)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.healthy)
                case .failed, .cancelled: finish(.unhealthy)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                finish(.unhealthy)
            }
        }
    }
}

// MARK: - Kill / restart

enum PortActions {
    static func pidExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// SIGTERM, then SIGKILL after a short grace period if it's still alive.
    /// Blocking — always call from a detached task, never from the main actor.
    static func killGraceful(pid: pid_t) {
        killGraceful(pids: [pid])
    }

    /// Signals every pid at once so N servers share one grace period instead of N.
    static func killGraceful(pids: [pid_t]) {
        let alive = Set(pids).filter(pidExists)
        guard !alive.isEmpty else { return }
        for pid in alive { kill(pid, SIGTERM) }
        Thread.sleep(forTimeInterval: 1.5)
        for pid in alive where pidExists(pid) {
            kill(pid, SIGKILL)
        }
    }

    /// Re-reads the process's live command line and cwd right before acting,
    /// rather than trusting a possibly-stale scan snapshot.
    static func captureCommandAndCwd(pid: pid_t) -> (command: String, cwd: String)? {
        let command = runShell("ps -o command= -p \(pid) 2>/dev/null")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }

        let cwdRaw = runShell("lsof -a -p \(pid) -d cwd -Fn 2>/dev/null")
        guard let line = cwdRaw.split(separator: "\n").first(where: { $0.hasPrefix("n") }) else {
            return nil
        }
        let cwd = String(line.dropFirst())
        guard cwd.hasPrefix("/") else { return nil }
        return (command, cwd)
    }

    /// Kills the process, then relaunches its captured command in its captured
    /// cwd, detached (survives Loadout quitting).
    static func restart(pid: pid_t) {
        guard let captured = captureCommandAndCwd(pid: pid) else { return }
        killGraceful(pid: pid)
        launchDetached(command: captured.command, cwd: captured.cwd)
    }

    private static func launchDetached(command: String, cwd: String) {
        let escapedCwd = cwd.replacingOccurrences(of: "'", with: "'\\''")
        // `command` is left unquoted (not wrapped in '...') so the shell can
        // still split it into argv the way it originally was.
        let script = "cd '\(escapedCwd)' && nohup \(command) >/dev/null 2>&1 &"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            // Nothing more we can do — surfaced to the user via the row staying dead.
        }
    }
}

// MARK: - Store

@MainActor
final class PortsStore: ObservableObject {
    @Published private(set) var ports: [PortEntry] = []
    @Published private(set) var health: [Int: PortHealth] = [:]
    @Published private(set) var isScanning = false

    private var autoRefreshTask: Task<Void, Never>?

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let scanned = await Task.detached { PortScanner.scan() }.value
            self.ports = scanned
            self.isScanning = false
            self.probeHealth(for: scanned)
        }
    }

    private func probeHealth(for entries: [PortEntry]) {
        let currentPorts = Set(entries.map { $0.port })
        health = health.filter { currentPorts.contains($0.key) }

        for entry in entries {
            if entry.isZombie {
                health[entry.port] = .unhealthy
                continue
            }
            if health[entry.port] == nil {
                health[entry.port] = .checking
            }
            let port = entry.port
            Task {
                let result = await HealthChecker.check(port: port)
                guard self.ports.contains(where: { $0.port == port }) else { return }
                self.health[port] = result
            }
        }
    }

    func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        refresh()
        autoRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if Task.isCancelled { return }
                self.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    func kill(_ entry: PortEntry) {
        let pid = entry.pid
        Task.detached {
            PortActions.killGraceful(pid: pid)
            await MainActor.run { self.refresh() }
        }
    }

    func killAll() {
        let pids = ports.map { $0.pid }
        Task.detached {
            PortActions.killGraceful(pids: pids)
            await MainActor.run { self.refresh() }
        }
    }

    func restart(_ entry: PortEntry) {
        let pid = entry.pid
        Task.detached {
            PortActions.restart(pid: pid)
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run { self.refresh() }
        }
    }
}

// MARK: - Views

struct TwoStepConfirmButton: View {
    let idleLabel: String
    let confirmLabel: String
    let systemImage: String
    let action: () -> Void

    @State private var awaitingConfirm = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            if awaitingConfirm {
                resetTask?.cancel()
                awaitingConfirm = false
                action()
            } else {
                awaitingConfirm = true
                resetTask?.cancel()
                resetTask = Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if !Task.isCancelled { awaitingConfirm = false }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: awaitingConfirm ? "exclamationmark.triangle.fill" : systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(awaitingConfirm ? confirmLabel : idleLabel)
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(awaitingConfirm ? Color.red : Color.red.opacity(0.12))
            .foregroundStyle(awaitingConfirm ? Color.white : Color.red)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct PortsSection: View {
    @ObservedObject var store: PortsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.ports.isEmpty ? "" : "\(store.ports.count) listening")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                TwoStepConfirmButton(
                    idleLabel: "Kill all",
                    confirmLabel: "Confirm kill all?",
                    systemImage: "xmark.octagon",
                    action: { store.killAll() }
                )
                .opacity(store.ports.isEmpty ? 0 : 1)
                .disabled(store.ports.isEmpty)
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)

            if store.ports.isEmpty {
                Text(store.isScanning ? "Scanning…" : "No dev servers listening.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            } else {
                ForEach(store.ports) { entry in
                    PortRow(
                        entry: entry,
                        health: store.health[entry.port] ?? .unknown,
                        onKill: { store.kill(entry) },
                        onRestart: { store.restart(entry) }
                    )
                }
            }
        }
        .onAppear { store.startAutoRefresh() }
        .onDisappear { store.stopAutoRefresh() }
    }
}

struct PortRow: View {
    let entry: PortEntry
    let health: PortHealth
    let onKill: () -> Void
    let onRestart: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HealthDot(health: health)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Button {
                    if let url = entry.url { NSWorkspace.shared.open(url) }
                } label: {
                    Text("localhost:\(entry.port)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Open http://localhost:\(entry.port)")

                HStack(spacing: 3) {
                    Text(entry.projectName ?? entry.processName)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let framework = entry.framework {
                        Text("· \(framework)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)

                HStack(spacing: 4) {
                    Text("PID \(entry.pid) · \(entry.processName)")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    if let uptime = entry.uptime {
                        Text("· up \(uptime)").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button(action: onRestart) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(!entry.canRestart)
                .help(entry.canRestart
                      ? "Restart — kill and relaunch the same command in the same directory"
                      : "Can't restart — no known working directory for this process")

                Button(action: onKill) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Kill — SIGTERM, then SIGKILL if it doesn't stop")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct HealthDot: View {
    let health: PortHealth

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(label)
    }

    private var color: Color {
        switch health {
        case .healthy: return .green
        case .unhealthy: return .red
        case .checking, .unknown: return .gray
        }
    }

    private var label: String {
        switch health {
        case .healthy: return "Responding"
        case .unhealthy: return "Not responding"
        case .checking: return "Checking…"
        case .unknown: return "Unknown"
        }
    }
}
