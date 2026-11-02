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
    /// Project folder with the home directory shortened to ~, e.g. ~/code/tea-house.
    var displayPath: String? { cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } }
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
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
    } catch {
        return ""
    }
    // Read before waiting: a pipe holds 64 KB, and a child that fills it (a full
    // `ps` listing does) blocks on write and never exits.
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
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
    /// With `stopGroup`, a pid whose process group is all dev tooling is stopped with
    /// its whole group, like Ctrl-C, so wrappers (pnpm, nodemon, turbo, `tsx watch`)
    /// can't respawn the server on the same port.
    static func killGraceful(pids: [pid_t], stopGroup: Bool = true) {
        let alive = Set(pids).filter(pidExists)
        guard !alive.isEmpty else { return }
        let groups = stopGroup ? devGroups(of: alive) : [:]
        let pgids = Set(groups.values)
        let loose = alive.filter { groups[$0] == nil }

        for pgid in pgids { killpg(pgid, SIGTERM) }
        for pid in loose { kill(pid, SIGTERM) }
        Thread.sleep(forTimeInterval: 1.5)
        for pgid in pgids where killpg(pgid, 0) == 0 { killpg(pgid, SIGKILL) }
        for pid in loose where pidExists(pid) { kill(pid, SIGKILL) }
    }

    private static let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "dash"]

    /// Maps each pid to its process group when every member of that group is a dev
    /// process or a shell: a terminal job, or a task shell an agent started. Groups
    /// holding anything else (an editor or app that spawned the server) are left out,
    /// and those pids get signalled alone.
    private static func devGroups(of pids: Set<pid_t>) -> [pid_t: pid_t] {
        let ownGroup = getpgrp()
        var wanted: [pid_t: pid_t] = [:]
        for pid in pids {
            let pgid = getpgid(pid)
            if pgid > 1 && pgid != ownGroup { wanted[pid] = pgid }
        }
        guard !wanted.isEmpty else { return [:] }

        var safe: [pid_t: Bool] = [:]
        for pgid in Set(wanted.values) { safe[pgid] = true }
        let raw = runShell("ps -axo pgid=,command= 2>/dev/null")
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pgid = pid_t(parts[0]), safe[pgid] == true else { continue }
            let command = String(parts[1])
            let argv0 = command.split(separator: " ").first.map(String.init) ?? command
            let name = (argv0 as NSString).lastPathComponent
            let isShell = shellNames.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
            if !isShell && !PortScanner.isDevProcess(processName: name, command: command) {
                safe[pgid] = false
            }
        }
        return wanted.filter { safe[$0.value] == true }
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
        // Only the listener: the relaunch runs its command alone, not the wrapper's.
        killGraceful(pids: [pid], stopGroup: false)
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
    enum PendingAction { case stopping, restarting }

    @Published private(set) var ports: [PortEntry] = []
    @Published private(set) var health: [Int: PortHealth] = [:]
    @Published private(set) var isScanning = false
    /// Ports with a kill/restart in flight. Cleared by the first scan that starts
    /// after the action finishes, so rows never flash back to idle before they vanish.
    @Published private(set) var pending: [Int: PendingAction] = [:]
    /// What the last kill did, e.g. "Stopped 3 servers". Shown briefly, then cleared.
    @Published private(set) var notice: String?

    private var autoRefreshTask: Task<Void, Never>?
    private var rescanQueued = false
    private var settledPorts: Set<Int> = []
    /// Killed ports whose outcome the next scan reports.
    private var killedPorts: Set<Int> = []
    private var noticeTask: Task<Void, Never>?

    func refresh() {
        guard !isScanning else {
            rescanQueued = true
            return
        }
        isScanning = true
        let settling = settledPorts
        let reporting = killedPorts
        settledPorts = []
        killedPorts = []
        Task {
            let scanned = await Task.detached { PortScanner.scan() }.value
            self.ports = scanned
            for port in settling { self.pending[port] = nil }
            if !reporting.isEmpty { self.report(killed: reporting, scanned: scanned) }
            self.isScanning = false
            self.probeHealth(for: scanned)
            if self.rescanQueued {
                self.rescanQueued = false
                self.refresh()
            }
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

    private func settle(_ ports: [Int], killed: Bool = false) {
        settledPorts.formUnion(ports)
        if killed { killedPorts.formUnion(ports) }
        refresh()
    }

    /// A port that is still listening after its kill either ignored the signals or
    /// was respawned by something outside its process group.
    private func report(killed: Set<Int>, scanned: [PortEntry]) {
        let survivors = killed.intersection(scanned.map(\.port)).sorted()
        let stopped = killed.count - survivors.count
        let stillRunning = survivors.map { ":\($0)" }.joined(separator: ", ")
        if survivors.isEmpty {
            notice = stopped == 1 ? "Stopped :\(killed.first!)" : "Stopped \(stopped) servers"
        } else if stopped > 0 {
            notice = "Stopped \(stopped) · \(stillRunning) still running"
        } else {
            notice = "\(stillRunning) didn't stop"
        }
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { self.notice = nil }
        }
    }

    func kill(_ entry: PortEntry) {
        let pid = entry.pid
        let port = entry.port
        pending[port] = .stopping
        Task.detached {
            PortActions.killGraceful(pid: pid)
            await MainActor.run { self.settle([port], killed: true) }
        }
    }

    func killAll() { kill(group: ports) }

    func kill(group: [PortEntry]) {
        let pids = group.map { $0.pid }
        let affected = group.map { $0.port }
        for port in affected { pending[port] = .stopping }
        Task.detached {
            PortActions.killGraceful(pids: pids)
            await MainActor.run { self.settle(affected, killed: true) }
        }
    }

    func restart(_ entry: PortEntry) {
        let pid = entry.pid
        let port = entry.port
        pending[port] = .restarting
        Task.detached {
            PortActions.restart(pid: pid)
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run { self.settle([port]) }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            HStack(spacing: 5) {
                ZStack {
                    if awaitingConfirm {
                        Image(systemName: "exclamationmark.triangle.fill").transition(.iconSwap)
                    } else {
                        Image(systemName: systemImage).transition(.iconSwap)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                ZStack {
                    // Holds the idle width, so a shorter confirm label can't pull the
                    // button out from under the cursor between the two clicks.
                    Text(idleLabel).hidden()
                    if awaitingConfirm {
                        Text(confirmLabel).transition(.textSwap)
                    } else {
                        Text(idleLabel).transition(.textSwap)
                    }
                }
            }
            .animation(reduceMotion ? nil : Motion.reveal, value: awaitingConfirm)
        }
        .buttonStyle(CapsuleButtonStyle(emphasized: awaitingConfirm))
    }
}

/// Neutral pill button. Uses primary/background so it inverts correctly in light and dark mode.
struct CapsuleButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        CapsuleButtonBody(configuration: configuration, emphasized: emphasized)
    }

    private struct CapsuleButtonBody: View {
        let configuration: Configuration
        let emphasized: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.control)
                // On the label only. Around the fill too, `.primary` would resolve to
                // this style, and fill and text would become the same color.
                .foregroundStyle(emphasized ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    Capsule().fill(emphasized ? AnyShapeStyle(Color.primary) : AnyShapeStyle(hovering ? Theme.hoverStrong.opacity(1.5) : Theme.hoverStrong))
                )
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .onHover { hovering = $0 }
                .animation(Motion.press, value: configuration.isPressed)
                .animation(Motion.hover, value: hovering)
                .animation(Motion.hover, value: emphasized)
        }
    }
}

/// Ports that belong to one project.
struct PortGroup: Identifiable, Hashable {
    /// Nil for servers running outside any project.
    let path: String?
    let ports: [PortEntry]

    var id: String { path ?? "" }
    var name: String { path.map { ($0 as NSString).lastPathComponent } ?? "Other" }
    var displayPath: String? { path.map { ($0 as NSString).abbreviatingWithTildeInPath } }

    /// Where a server runs relative to its project. Nil when it's the project itself.
    func subfolder(of entry: PortEntry) -> String? {
        guard let path, let cwd = entry.cwd, cwd != path else { return nil }
        let prefix = path + "/"
        return cwd.hasPrefix(prefix) ? String(cwd.dropFirst(prefix.count)) : cwd
    }

    /// The deepest known project containing a server's folder wins. Failing that, the
    /// server's own folder is its project, unless that's home or the disk root, which
    /// say nothing about what it belongs to. Other always sorts last.
    static func make(from ports: [PortEntry], known: [String], home: String) -> [PortGroup] {
        let candidates = known.filter { $0 != home && $0 != "/" }
        let grouped = Dictionary(grouping: ports) { entry -> String? in
            guard let cwd = entry.cwd, cwd != home, cwd != "/" else { return nil }
            return ProjectCatalog.owner(of: cwd, among: candidates) ?? cwd
        }
        return grouped
            .map { PortGroup(path: $0.key, ports: $0.value.sorted { $0.port < $1.port }) }
            .sorted { a, b in
                if (a.path == nil) != (b.path == nil) { return b.path == nil }
                return a.name.lowercased() < b.name.lowercased()
            }
    }
}

/// Always on screen at the top of the panel, so it stays small: up to three servers to a
/// row. Lists every server whichever project is chosen, because this says what's running
/// on the machine. Everything else about a server is in its tooltip, and its actions
/// appear on hover.
struct PortsSection: View {
    @ObservedObject var store: PortsStore
    let knownProjects: [String]
    var onOpenProject: (String) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let perRow = 3
    private static let cellHeight: CGFloat = 26
    private static let cellGap: CGFloat = 4
    /// Past this the list scrolls, so a lot of servers can't push the tools off the panel.
    /// Between two rows on purpose: a row cut in half says there's more.
    private static let maxListHeight: CGFloat = 133

    private var groups: [PortGroup] {
        PortGroup.make(from: store.ports, known: knownProjects, home: NSHomeDirectory())
    }

    /// The cells are a fixed height, so the list's height is known without measuring.
    private var listHeight: CGFloat {
        let rows = (store.ports.count + Self.perRow - 1) / Self.perRow
        return CGFloat(rows) * Self.cellHeight + CGFloat(max(0, rows - 1)) * Self.cellGap
    }

    private var status: String? {
        if let notice = store.notice { return notice }
        if store.ports.isEmpty { return store.isScanning ? "Scanning…" : "No dev servers running" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if !store.ports.isEmpty {
                ScrollView {
                    list
                }
                .scrollDisabled(listHeight <= Self.maxListHeight)
                .scrollIndicators(.automatic)
                .frame(height: min(listHeight, Self.maxListHeight))
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(
                            colors: [.black, listHeight > Self.maxListHeight ? .clear : .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 14)
                    }
                }
                .padding(.horizontal, Theme.rowInset)
            }
        }
        .padding(.bottom, 10)
        .animation(reduceMotion ? nil : Motion.reveal, value: store.ports.map(\.port))
        .onAppear { store.startAutoRefresh() }
        .onDisappear { store.stopAutoRefresh() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("PORTS")
                .font(.sectionLabel)
                .tracking(0.6)
                .foregroundStyle(.secondary)
            if !store.ports.isEmpty {
                Text(verbatim: "\(store.ports.count)")
                    .font(.sectionLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let status {
                Text(verbatim: status)
                    .font(.rowMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(status)
            }
            Spacer(minLength: 6)
            if store.ports.count > 1 {
                let what = "all \(store.ports.count) servers"
                TwoStepIconButton(help: "Kill \(what)", action: { store.killAll() })
                    .accessibilityLabel("Kill \(what)")
            }
        }
        .frame(height: 24)
        .padding(.leading, Theme.gutter)
        .padding(.trailing, Theme.rowInset + 2)
    }

    /// One grid, ordered by project, so a row fills up before the next one starts.
    private var list: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Self.cellGap), count: Self.perRow),
            spacing: Self.cellGap
        ) {
            ForEach(groups) { group in
                ForEach(group.ports) { entry in
                    PortCell(
                        entry: entry,
                        group: group,
                        location: group.path == nil ? (entry.displayPath ?? entry.processName) : group.subfolder(of: entry),
                        health: store.health[entry.port] ?? .unknown,
                        pending: store.pending[entry.port],
                        onKill: { store.kill(entry) },
                        onRestart: { store.restart(entry) },
                        onKillGroup: { store.kill(group: group.ports) },
                        onOpenProject: group.path.map { path in { onOpenProject(path) } }
                    )
                    .frame(height: Self.cellHeight)
                    .transition(.opacity)
                }
            }
        }
    }
}

struct PortCell: View {
    let entry: PortEntry
    let group: PortGroup
    /// Subfolder within the group's project.
    var location: String?
    let health: PortHealth
    let pending: PortsStore.PendingAction?
    let onKill: () -> Void
    let onRestart: () -> Void
    let onKillGroup: () -> Void
    let onOpenProject: (() -> Void)?

    @State private var hovering = false
    @FocusState private var focused: Part?

    private enum Part { case open, restart, kill }

    /// A plain string first: an Int interpolated into a label gets locale grouping, "38,006".
    private var address: String { "localhost:\(entry.port)" }

    /// Keyboard users get the same actions as the pointer.
    private var showsActions: Bool { pending == nil && (hovering || focused != nil) }

    private var details: String {
        var lines = [address, group.displayPath ?? group.name]
        if let framework = entry.framework { lines.append(framework) }
        if let location { lines.append(location) }
        var process = [entry.processName, "PID \(entry.pid)"]
        if let uptime = entry.uptime { process.append("up \(uptime)") }
        lines.append(process.joined(separator: " · "))
        return lines.joined(separator: "\n")
    }

    private func open() {
        if let url = entry.url { NSWorkspace.shared.open(url) }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 5) {
                    HealthDot(health: pending == nil ? health : .checking)
                    Text(verbatim: ":\(entry.port)")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    if !showsActions, pending == nil {
                        Text(verbatim: group.name)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .open)
            .accessibilityLabel(address)
            .accessibilityValue(details)
            .accessibilityAction(named: "Restart") { if entry.canRestart { onRestart() } }
            .accessibilityAction(named: "Kill", onKill)
            .accessibilityAction(named: "Tools for \(group.name)") { onOpenProject?() }

            if pending != nil {
                ProgressView().controlSize(.mini).padding(.trailing, 5)
            } else if showsActions {
                IconButton(
                    systemName: "arrow.clockwise",
                    help: entry.canRestart
                        ? "Restart: kill and relaunch the same command in the same folder"
                        : "Can't restart: no known folder for this process",
                    size: 22,
                    action: onRestart
                )
                .disabled(!entry.canRestart)
                .focused($focused, equals: .restart)
                .accessibilityLabel("Restart \(address)")
                TwoStepIconButton(help: "Kill: SIGTERM, then SIGKILL if it doesn't stop", action: onKill)
                    .focused($focused, equals: .kill)
                    .accessibilityLabel("Kill \(address)")
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Theme.hoverStrong : Theme.track)
        )
        .opacity(pending == nil ? 1 : 0.6)
        .help(details)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: pending)
        .contextMenu {
            Button("Open \(address)", action: open)
            Button("Restart", action: onRestart).disabled(!entry.canRestart || pending != nil)
            Button("Kill", action: onKill).disabled(pending != nil)
            if onOpenProject != nil || group.ports.count > 1 {
                Divider()
            }
            if let onOpenProject {
                Button("Tools for \(group.name)", action: onOpenProject)
            }
            if group.ports.count > 1 {
                Button("Kill the \(group.ports.count) servers in \(group.name)", action: onKillGroup)
            }
        }
    }
}

/// An × that asks once before it acts. It appears on hover in a tight row, so one stray
/// click shouldn't stop a server.
struct TwoStepIconButton: View {
    let help: String
    let action: () -> Void

    @State private var armed = false
    @State private var hovering = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            resetTask?.cancel()
            if armed {
                armed = false
                action()
            } else {
                armed = true
                resetTask = Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if !Task.isCancelled { armed = false }
                }
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(armed ? Color.primary : (hovering ? Theme.hoverStrong : .clear))
                ZStack {
                    if armed {
                        Image(systemName: "exclamationmark")
                            .foregroundStyle(.background)
                            .transition(.iconSwap)
                    } else {
                        Image(systemName: "xmark")
                            .foregroundStyle(hovering ? Color.primary : Color.secondary)
                            .transition(.iconSwap)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.reveal, value: armed)
        .help(armed ? "Click again to confirm" : help)
    }
}

struct HealthDot: View {
    let health: PortHealth

    var body: some View {
        StatusDot(color: color)
            .animation(Motion.hover, value: health)
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
