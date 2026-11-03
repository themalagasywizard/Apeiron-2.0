import Foundation

public enum TextUtils {
    /// Keeps the head and tail of long text with a marker in between.
    public static func truncateMiddle(_ text: String, maxCharacters: Int, note: String? = nil) -> String {
        guard text.count > maxCharacters, maxCharacters > 200 else { return text }
        let headCount = Int(Double(maxCharacters) * 0.6)
        let tailCount = maxCharacters - headCount
        let head = text.prefix(headCount)
        let tail = text.suffix(tailCount)
        let omitted = text.count - headCount - tailCount
        let marker = note ?? "… \(omitted) characters omitted …"
        return "\(head)\n\n[\(marker)]\n\n\(tail)"
    }

    /// Rough token estimate. Providers report real counts after each
    /// response; this only covers text appended since then.
    public static func estimateTokens(_ text: String) -> Int {
        max(1, text.utf8.count / 4)
    }

    public static func estimateTokens(_ message: ChatMessage) -> Int {
        var total = 4
        for block in message.blocks {
            switch block {
            case .text(let text): total += estimateTokens(text)
            case .thinking(let text, _): total += estimateTokens(text)
            case .redactedThinking(let data): total += data.count / 4
            case .toolCall(let call): total += estimateTokens(call.input.serialized()) + 8
            case .toolResult(let result): total += estimateTokens(result.content) + 8
            case .image: total += 1_500
            case .opaque(_, let json): total += estimateTokens(json.serialized())
            }
        }
        return total
    }

    public static func isProbablyBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8_000)
        if sample.contains(0) { return true }
        return String(data: sample, encoding: .utf8) == nil && String(data: sample.dropLast(4), encoding: .utf8) == nil
    }

    /// Collapses an HTML document to readable text.
    public static func htmlToText(_ html: String) -> String {
        var text = html
        let patterns: [(String, String)] = [
            ("(?is)<(script|style|noscript|svg|head)[^>]*>.*?</\\1>", " "),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</(p|div|section|article|li|h[1-6]|tr|pre|blockquote)>", "\n"),
            ("(?i)<li[^>]*>", "\n• "),
            ("(?i)<h([1-6])[^>]*>", "\n\n## "),
            ("(?s)<[^>]+>", ""),
        ]
        for (pattern, replacement) in patterns {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n\\s*\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Glob matching for file search (`*`, `**`, `?`, `{a,b}`, `[abc]`).
public struct GlobPattern: Sendable {
    public let pattern: String
    private let regex: NSRegularExpression?

    public init(_ pattern: String) {
        self.pattern = pattern
        self.regex = try? NSRegularExpression(pattern: Self.regexSource(for: pattern))
    }

    public func matches(_ path: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, range: range) != nil
    }

    static func regexSource(for glob: String) -> String {
        var result = "^"
        let characters = Array(glob)
        var index = 0
        var braceDepth = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        result += "(?:.*/)?"
                        index += 3
                        continue
                    }
                    result += ".*"
                    index += 2
                    continue
                }
                result += "[^/]*"
            case "?": result += "[^/]"
            case "{":
                braceDepth += 1
                result += "(?:"
            case "}" where braceDepth > 0:
                braceDepth -= 1
                result += ")"
            case "," where braceDepth > 0:
                result += "|"
            case "[":
                if let close = characters[index...].firstIndex(of: "]") {
                    var set = String(characters[(index + 1)..<close])
                    if set.hasPrefix("!") { set = "^" + set.dropFirst() }
                    result += "[\(set)]"
                    index = close + 1
                    continue
                }
                result += "\\["
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return result + "$"
    }
}

/// Line-based diff (LCS) used for previews and the changes panel.
public enum LineDiff {
    public enum Kind: String, Sendable, Codable { case context, added, removed }

    public struct Line: Hashable, Sendable {
        public var kind: Kind
        public var text: String
        public var oldNumber: Int?
        public var newNumber: Int?
    }

    public struct Hunk: Hashable, Sendable {
        public var lines: [Line]
        public var header: String
    }

    public static func lines(before: String, after: String) -> [Line] {
        let old = before.isEmpty ? [] : before.components(separatedBy: "\n")
        let new = after.isEmpty ? [] : after.components(separatedBy: "\n")
        // Trim common prefix/suffix to keep the LCS table small.
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let oldMid = Array(old[prefix..<(old.count - suffix)])
        let newMid = Array(new[prefix..<(new.count - suffix)])

        var result: [Line] = []
        for i in 0..<prefix {
            result.append(Line(kind: .context, text: old[i], oldNumber: i + 1, newNumber: i + 1))
        }
        if oldMid.count * newMid.count > 4_000_000 {
            for (i, line) in oldMid.enumerated() {
                result.append(Line(kind: .removed, text: line, oldNumber: prefix + i + 1, newNumber: nil))
            }
            for (i, line) in newMid.enumerated() {
                result.append(Line(kind: .added, text: line, oldNumber: nil, newNumber: prefix + i + 1))
            }
        } else {
            let n = oldMid.count, m = newMid.count
            var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
            if n > 0 && m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        table[i][j] = oldMid[i] == newMid[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < n || j < m {
                if i < n, j < m, oldMid[i] == newMid[j] {
                    result.append(Line(kind: .context, text: oldMid[i], oldNumber: prefix + i + 1, newNumber: prefix + j + 1))
                    i += 1; j += 1
                } else if i < n, j == m || table[i + 1][j] >= table[i][j + 1] {
                    result.append(Line(kind: .removed, text: oldMid[i], oldNumber: prefix + i + 1, newNumber: nil))
                    i += 1
                } else {
                    result.append(Line(kind: .added, text: newMid[j], oldNumber: nil, newNumber: prefix + j + 1))
                    j += 1
                }
            }
        }
        let oldOffset = old.count - suffix, newOffset = new.count - suffix
        for k in 0..<suffix {
            result.append(Line(kind: .context, text: old[oldOffset + k], oldNumber: oldOffset + k + 1, newNumber: newOffset + k + 1))
        }
        return result
    }

    /// Groups changed lines into hunks with `context` lines around them.
    public static func hunks(before: String, after: String, context: Int = 3) -> [Hunk] {
        let all = lines(before: before, after: after)
        let changed = all.indices.filter { all[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let range = max(0, index - context)...min(all.count - 1, index + context)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        return ranges.map { range in
            let slice = Array(all[range])
            let oldStart = slice.first { $0.oldNumber != nil }?.oldNumber ?? 0
            let newStart = slice.first { $0.newNumber != nil }?.newNumber ?? 0
            let oldCount = slice.filter { $0.kind != .added }.count
            let newCount = slice.filter { $0.kind != .removed }.count
            return Hunk(lines: slice, header: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
        }
    }

    public static func stats(before: String, after: String) -> (added: Int, removed: Int) {
        let all = lines(before: before, after: after)
        return (all.filter { $0.kind == .added }.count, all.filter { $0.kind == .removed }.count)
    }

    public static func unified(path: String, before: String, after: String) -> String {
        var output = "--- a/\(path)\n+++ b/\(path)\n"
        for hunk in hunks(before: before, after: after) {
            output += hunk.header + "\n"
            for line in hunk.lines {
                let marker = line.kind == .added ? "+" : line.kind == .removed ? "-" : " "
                output += marker + line.text + "\n"
            }
        }
        return output
    }
}
