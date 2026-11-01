import Foundation
import CryptoKit

enum LoadoutError: LocalizedError {
    case readOnly(String)
    case notJSONObject(String)
    case changedElsewhere(String)

    var errorDescription: String? {
        switch self {
        case .readOnly(let file): return "Read-only run: not writing \(file)"
        case .notJSONObject(let file): return "\(file) isn't a JSON object. Fix it by hand, then try again."
        case .changedElsewhere(let file): return "\(file) changed since then, so undo stopped to keep that change."
        }
    }
}

/// Reads a JSON object. A missing or empty file reads as an empty object.
func readJSONObject(_ url: URL) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    let data = try Data(contentsOf: url)
    if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw LoadoutError.notJSONObject(url.lastPathComponent)
    }
    return json
}

func encodeJSONObject(_ json: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(
        withJSONObject: json,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    data.append(0x0A)
    return data
}

private func sha(_ data: Data?) -> String {
    guard let data else { return "absent" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Every write Loadout makes goes through here. Writes are atomic, keep the file's
/// permissions, and record what's needed to undo them as one user action.
final class ConfigWriter {
    fileprivate struct FileChange {
        let url: URL
        let before: Data?
        var afterHash: String
    }

    fileprivate struct LinkChange {
        let url: URL
        let beforeDestination: String?
    }

    /// One user action, undoable as a unit.
    final class Change {
        fileprivate var files: [URL: FileChange] = [:]
        fileprivate var links: [URL: LinkChange] = [:]
        /// Targeted inverses for files too busy to restore whole (`~/.claude.json`).
        fileprivate var inverses: [() throws -> Void] = []
        var isEmpty: Bool { files.isEmpty && links.isEmpty && inverses.isEmpty }
    }

    let readOnly: Bool
    private(set) var current = Change()

    init(readOnly: Bool = false) {
        self.readOnly = readOnly
    }

    /// Ends the current action and returns it for the undo stack.
    func finishChange() -> Change {
        let done = current
        current = Change()
        return done
    }

    private func guardWritable(_ url: URL) throws {
        if readOnly { throw LoadoutError.readOnly(url.lastPathComponent) }
    }

    private func capture(_ url: URL) {
        guard current.files[url] == nil else { return }
        let before = try? Data(contentsOf: url)
        current.files[url] = FileChange(url: url, before: before, afterHash: sha(before))
    }

    /// Reads, mutates and writes a JSON file. With `removeIfEmpty`, an object left
    /// empty deletes the file, along with its folder if that's now empty too.
    func editJSON(_ url: URL, removeIfEmpty: Bool = false, _ mutate: (inout [String: Any]) -> Void) throws {
        try guardWritable(url)
        var json = try readJSONObject(url)
        mutate(&json)
        capture(url)
        if json.isEmpty && removeIfEmpty {
            try deleteFile(url)
        } else {
            try write(try encodeJSONObject(json), to: url)
        }
    }

    /// Same as `editJSON`, but for files other programs rewrite constantly: nothing is
    /// restored whole. `inverse` runs on undo, against whatever the file holds by then.
    func editJSONTargeted(
        _ url: URL,
        _ mutate: (inout [String: Any]) -> Void,
        inverse: @escaping (inout [String: Any]) -> Void
    ) throws {
        try guardWritable(url)
        var json = try readJSONObject(url)
        mutate(&json)
        try atomicWrite(try encodeJSONObject(json), to: url)
        current.inverses.append { [weak self] in
            guard let self else { return }
            var latest = try readJSONObject(url)
            inverse(&latest)
            try self.atomicWrite(try encodeJSONObject(latest), to: url)
        }
    }

    func writeText(_ text: String, to url: URL, removeIfBlank: Bool = false) throws {
        try guardWritable(url)
        capture(url)
        if removeIfBlank && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try deleteFile(url)
        } else {
            try write(Data(text.utf8), to: url)
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try atomicWrite(data, to: url)
        current.files[url]?.afterHash = sha(data)
    }

    private func deleteFile(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        current.files[url]?.afterHash = sha(nil)
        removeFolderIfEmpty(url.deletingLastPathComponent())
    }

    private func removeFolderIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        if items.filter({ $0 != ".DS_Store" }).isEmpty { try? fm.removeItem(at: dir) }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        let tmp = url.appendingPathExtension("loadout-tmp")
        try data.write(to: tmp, options: .atomic)
        if let permissions {
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: tmp.path)
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }

    // MARK: Symlinks

    func symlink(_ url: URL, to destination: URL) throws {
        try guardWritable(url)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if current.links[url] == nil {
            current.links[url] = LinkChange(url: url, beforeDestination: try? fm.destinationOfSymbolicLink(atPath: url.path))
        }
        try? fm.removeItem(at: url)
        try fm.createSymbolicLink(at: url, withDestinationURL: destination)
    }

    func removeSymlink(_ url: URL) throws {
        try guardWritable(url)
        let fm = FileManager.default
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) else { return }
        if current.links[url] == nil {
            current.links[url] = LinkChange(url: url, beforeDestination: destination)
        }
        try fm.removeItem(at: url)
        removeFolderIfEmpty(url.deletingLastPathComponent())
        removeFolderIfEmpty(url.deletingLastPathComponent().deletingLastPathComponent())
    }

    // MARK: Undo

    /// Restores one action. Stops before writing anything if a file changed since,
    /// so undo can't throw away an edit made somewhere else.
    func undo(_ change: Change) throws {
        try guardWritable(URL(fileURLWithPath: "undo"))
        for file in change.files.values {
            let now = try? Data(contentsOf: file.url)
            if sha(now) != file.afterHash { throw LoadoutError.changedElsewhere(file.url.lastPathComponent) }
        }
        let fm = FileManager.default
        for file in change.files.values {
            if let before = file.before {
                try atomicWrite(before, to: file.url)
            } else if fm.fileExists(atPath: file.url.path) {
                try fm.removeItem(at: file.url)
                removeFolderIfEmpty(file.url.deletingLastPathComponent())
            }
        }
        for link in change.links.values {
            try? fm.removeItem(at: link.url)
            if let destination = link.beforeDestination {
                try fm.createDirectory(at: link.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(atPath: link.url.path, withDestinationPath: destination)
            } else {
                removeFolderIfEmpty(link.url.deletingLastPathComponent())
                removeFolderIfEmpty(link.url.deletingLastPathComponent().deletingLastPathComponent())
            }
        }
        for inverse in change.inverses.reversed() { try inverse() }
    }
}

// MARK: - Shell

/// Runs a command through a login shell and returns stdout. Reads before waiting, so
/// a long listing can't fill the pipe and hang the child.
func runLoginShell(_ command: String, cwd: URL? = nil) -> (output: String, status: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", command]
    if let cwd { p.currentDirectoryURL = cwd }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return ("", -1) }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Keeping generated files out of a repo

enum GitExclude {
    private static func git(_ args: [String], in dir: URL) -> (output: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ("", -1) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }

    /// Looks for `.git` first, so a folder that isn't a repo never launches git.
    private static func isInRepo(_ dir: URL) -> Bool {
        var current = dir.standardizedFileURL
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { return true }
            current.deleteLastPathComponent()
        }
        return false
    }

    /// Keeps a generated file out of git status by listing it in `.git/info/exclude`,
    /// which nobody commits. Returns true when the repo already tracks the file, in
    /// which case the caller is merging into a shared file and nothing is excluded.
    @discardableResult
    static func exclude(_ relativePath: String, in project: URL) -> Bool {
        guard isInRepo(project) else { return false }
        if git(["ls-files", "--error-unmatch", relativePath], in: project).status == 0 { return true }
        let raw = git(["rev-parse", "--git-path", "info/exclude"], in: project).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }
        let excludeUrl = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : project.appendingPathComponent(raw)
        let existing = (try? String(contentsOf: excludeUrl, encoding: .utf8)) ?? ""
        let line = "/" + relativePath
        guard !existing.split(separator: "\n").contains(Substring(line)) else { return false }
        let prefix = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try? FileManager.default.createDirectory(at: excludeUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (existing + prefix + line + "\n").write(to: excludeUrl, atomically: true, encoding: .utf8)
        return false
    }
}
