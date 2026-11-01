import Foundation

/// A small line-based TOML reader and editor for the handful of keys Loadout touches
/// in Codex config. It edits lines in place, so comments and formatting survive,
/// which a parse-and-reprint can't promise. Not a full TOML parser: it understands
/// `[table]` headers and single `key = value` lines.
struct TOMLDocument {
    private(set) var lines: [String]

    struct Section {
        let path: [String]
        /// Index of the header line.
        let header: Int
        /// Index past the last line of this section.
        let end: Int
    }

    init(_ text: String) {
        var split = text.components(separatedBy: "\n")
        if split.last == "" { split.removeLast() }
        lines = split
    }

    var text: String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }

    var isBlank: Bool {
        lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: Paths

    /// `plugins."a@b".enabled` → ["plugins", "a@b", "enabled"].
    static func parsePath(_ raw: String) -> [String]? {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var hadQuoted = false
        for ch in raw {
            if let q = quote {
                if escaped { current.append(ch); escaped = false; continue }
                if ch == "\\" && q == "\"" { escaped = true; continue }
                if ch == q { quote = nil; continue }
                current.append(ch)
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hadQuoted = true
            } else if ch == "." {
                let trimmed = hadQuoted ? current : current.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                parts.append(trimmed)
                current = ""
                hadQuoted = false
            } else if ch == " " || ch == "\t" {
                continue
            } else {
                current.append(ch)
            }
        }
        guard quote == nil, !current.isEmpty else { return nil }
        parts.append(current)
        return parts
    }

    static func header(for path: [String]) -> String {
        "[" + path.map(encodeSegment).joined(separator: ".") + "]"
    }

    private static func encodeSegment(_ segment: String) -> String {
        let bare = segment.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-"
        }
        return bare && !segment.isEmpty ? segment : quote(segment)
    }

    static func quote(_ value: String) -> String {
        var out = "\""
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    static func array(_ values: [String]) -> String {
        "[" + values.map(quote).joined(separator: ", ") + "]"
    }

    // MARK: Reading

    var sections: [Section] {
        var result: [Section] = []
        var depth = 0
        var parsed: [(path: [String]?, header: Int)] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if depth == 0 && trimmed.hasPrefix("[") {
                if trimmed.hasPrefix("[[") {
                    parsed.append((nil, index))
                } else if let close = Self.closingBracket(trimmed) {
                    let inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                    parsed.append((Self.parsePath(inner), index))
                } else {
                    parsed.append((nil, index))
                }
                continue
            }
            depth = max(0, depth + Self.bracketDelta(line))
        }
        for (i, entry) in parsed.enumerated() {
            guard let path = entry.path else { continue }
            let end = i + 1 < parsed.count ? parsed[i + 1].header : lines.count
            result.append(Section(path: path, header: entry.header, end: end))
        }
        return result
    }

    private static func closingBracket(_ line: String) -> String.Index? {
        var quote: Character?
        for index in line.indices {
            let ch = line[index]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "]" {
                return index
            }
        }
        return nil
    }

    /// Net `[` minus `]` outside strings and comments, to spot multi-line arrays.
    private static func bracketDelta(_ line: String) -> Int {
        var delta = 0
        var quote: Character?
        var escaped = false
        for ch in line {
            if let q = quote {
                if escaped { escaped = false; continue }
                if ch == "\\" && q == "\"" { escaped = true; continue }
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'": quote = ch
            case "#": return delta
            case "[": delta += 1
            case "]": delta -= 1
            default: break
            }
        }
        return delta
    }

    func section(_ path: [String]) -> Section? {
        sections.first { $0.path == path }
    }

    /// Key/value pairs of a section's single-line assignments, with raw values.
    func entries(_ section: Section) -> [(key: String, raw: String, line: Int)] {
        var result: [(String, String, Int)] = []
        var depth = 0
        var index = section.header + 1
        while index < section.end {
            let line = lines[index]
            defer { index += 1 }
            if depth > 0 {
                depth = max(0, depth + Self.bracketDelta(line))
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eq = Self.assignmentEquals(trimmed) else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let raw = Self.stripComment(String(trimmed[trimmed.index(after: eq)...]))
                .trimmingCharacters(in: .whitespaces)
            result.append((Self.parsePath(key)?.joined(separator: ".") ?? key, raw, index))
            depth = max(0, Self.bracketDelta(raw))
        }
        return result
    }

    private static func assignmentEquals(_ line: String) -> String.Index? {
        var quote: Character?
        for index in line.indices {
            let ch = line[index]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "=" {
                return index
            }
        }
        return nil
    }

    private static func stripComment(_ value: String) -> String {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let ch = value[index]
            if let q = quote {
                if escaped { escaped = false; continue }
                if ch == "\\" && q == "\"" { escaped = true; continue }
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "#" {
                return String(value[..<index])
            }
        }
        return value
    }

    func raw(_ path: [String], _ key: String) -> String? {
        guard let section = section(path) else { return nil }
        return entries(section).first { $0.key == key }?.raw
    }

    func bool(_ path: [String], _ key: String) -> Bool? {
        switch raw(path, key) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    func string(_ path: [String], _ key: String) -> String? {
        guard let raw = raw(path, key), raw.count >= 2 else { return nil }
        guard let first = raw.first, first == "\"" || first == "'", raw.last == first else { return nil }
        let inner = String(raw.dropFirst().dropLast())
        guard first == "\"" else { return inner }
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// A single-line array of strings. Multi-line arrays read as nil.
    func stringArray(_ path: [String], _ key: String) -> [String]? {
        guard let raw = raw(path, key), raw.hasPrefix("["), raw.hasSuffix("]") else { return nil }
        guard let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return array
    }

    /// Second path segments of every table under a root, e.g. server names under `mcp_servers`.
    func children(of root: String) -> [String] {
        var seen: [String] = []
        for section in sections where section.path.count >= 2 && section.path[0] == root {
            if !seen.contains(section.path[1]) { seen.append(section.path[1]) }
        }
        return seen
    }

    // MARK: Editing

    /// Sets a key, replacing it in place if present and adding the section if needed.
    /// `rawValue` is written as is, so it must already be valid TOML.
    mutating func set(_ path: [String], _ key: String, rawValue: String) {
        if let section = section(path) {
            if let existing = entries(section).first(where: { $0.key == key }) {
                let indent = String(lines[existing.line].prefix { $0 == " " || $0 == "\t" })
                lines[existing.line] = "\(indent)\(key) = \(rawValue)"
            } else {
                lines.insert("\(key) = \(rawValue)", at: section.header + 1)
            }
            return
        }
        if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("")
        }
        lines.append(Self.header(for: path))
        lines.append("\(key) = \(rawValue)")
    }

    mutating func remove(_ path: [String], _ key: String) {
        guard let section = section(path),
              let entry = entries(section).first(where: { $0.key == key }) else { return }
        lines.remove(at: entry.line)
    }

    /// Removes a table with everything in it, plus the blank line that set it off.
    mutating func removeSection(_ path: [String]) {
        guard let section = section(path) else { return }
        lines.removeSubrange(section.header..<section.end)
        if section.header > 0, section.header <= lines.count,
           lines[section.header - 1].trimmingCharacters(in: .whitespaces).isEmpty,
           section.header == lines.count || lines[section.header].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            lines.remove(at: section.header - 1)
        }
    }

    /// True when the table holds no keys, comments aside.
    func isEmpty(_ path: [String]) -> Bool {
        guard let section = section(path) else { return true }
        return entries(section).isEmpty
    }
}
