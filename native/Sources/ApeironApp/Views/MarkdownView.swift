import SwiftUI

/// A Markdown block.
enum MarkdownBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String, closed: Bool)
    case list(ordered: Bool, items: [ListItem])
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule

    struct ListItem: Hashable {
        var indent: Int
        var marker: String
        var text: String
        var checked: Bool?
    }
}

/// Small, streaming-tolerant Markdown block parser. Unclosed fences render as
/// code while a response is still arriving.
enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                var closed = false
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        closed = true
                        break
                    }
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n"), closed: closed))
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // Heading
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                if hashes <= 6, trimmed.dropFirst(hashes).first == " " {
                    flushParagraph()
                    blocks.append(.heading(level: hashes, text: trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)))
                    index += 1
                    continue
                }
            }

            // Rule
            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1,
               let first = trimmed.first, "-*_".contains(first), paragraph.isEmpty {
                blocks.append(.rule)
                index += 1
                continue
            }

            // Table
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Quote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            // Lists
            if let first = listItem(line) {
                flushParagraph()
                let ordered = first.marker.last == "." || first.marker.last == ")"
                var items = [first]
                index += 1
                while index < lines.count {
                    let next = lines[index]
                    if let item = listItem(next) {
                        items.append(item)
                    } else if !next.trimmingCharacters(in: .whitespaces).isEmpty, next.hasPrefix("  ") || next.hasPrefix("\t") {
                        items[items.count - 1].text += " " + next.trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func listItem(_ line: String) -> MarkdownBlock.ListItem? {
        let indentCount = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        var marker = ""
        var rest = Substring("")
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            marker = "•"
            rest = body.dropFirst(2)
        } else {
            let digits = body.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count < 4 else { return nil }
            let after = body.dropFirst(digits.count)
            guard let punct = after.first, punct == "." || punct == ")", after.dropFirst().first == " " else { return nil }
            marker = "\(digits)."
            rest = after.dropFirst(2)
        }
        var text = String(rest)
        var checked: Bool?
        if text.hasPrefix("[ ] ") { checked = false; text = String(text.dropFirst(4)) }
        else if text.lowercased().hasPrefix("[x] ") { checked = true; text = String(text.dropFirst(4)) }
        return MarkdownBlock.ListItem(indent: indentCount / 2, marker: marker, text: text, checked: checked)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Inline Markdown (bold, italic, code, links) as an AttributedString.
    static func inline(_ text: String, codeColor: Color) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attributed[run.range].font = Font.system(size: 13, weight: .regular, design: .monospaced)
                attributed[run.range].foregroundColor = codeColor
                attributed[run.range].backgroundColor = Palette.code
            }
        }
        return attributed
    }
}

struct MarkdownView: View {
    var text: String
    var isStreaming = false
    @Environment(\.theme) private var theme

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownParser.inline(text, codeColor: theme.accentColor))
                .font(headingFont(level))
                .foregroundStyle(Palette.textPrimary)
                .padding(.top, level <= 2 ? 6 : 2)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(MarkdownParser.inline(text, codeColor: theme.accentColor))
                .font(theme.body())
                .foregroundStyle(Palette.textPrimary)
                .lineSpacing(4.5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .code(let language, let code, let closed):
            CodeBlockView(language: language, code: code, isStreaming: isStreaming && !closed)
        case .list(_, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(checked ? theme.accentColor : Palette.textTertiary)
                            } else {
                                Text(item.marker)
                                    .foregroundStyle(item.marker == "•" ? theme.accentColor : Palette.textSecondary)
                            }
                        }
                        .font(theme.body())
                        .frame(minWidth: 14, alignment: .trailing)
                        Text(MarkdownParser.inline(item.text, codeColor: theme.accentColor))
                            .font(theme.body())
                            .foregroundStyle(Palette.textPrimary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.indent) * 18)
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5).fill(theme.accentColor.opacity(0.5)).frame(width: 3)
                Text(MarkdownParser.inline(text, codeColor: theme.accentColor))
                    .font(theme.body().italic())
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows)
        case .rule:
            Rectangle().fill(Palette.border).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return theme.body(22).weight(.semibold)
        case 2: return theme.body(19).weight(.semibold)
        case 3: return theme.body(16.5).weight(.semibold)
        default: return theme.body(15).weight(.semibold)
        }
    }
}

struct MarkdownTableView: View {
    var header: [String]
    var rows: [[String]]
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownParser.inline(cell, codeColor: theme.accentColor))
                            .font(theme.ui(13, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
                .background(Palette.surfaceSunken)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<header.count, id: \.self) { column in
                            Text(MarkdownParser.inline(column < row.count ? row[column] : "", codeColor: theme.accentColor))
                                .font(theme.ui(13))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .textSelection(.enabled)
                        }
                    }
                    .background(index % 2 == 1 ? Palette.surfaceSunken.opacity(0.5) : Color.clear)
                }
            }
            .foregroundStyle(Palette.textPrimary)
            .card()
            .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        }
    }
}

struct CodeBlockView: View {
    var language: String?
    var code: String
    var isStreaming = false
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language?.lowercased() ?? "code")
                    .font(theme.ui(11.5, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
                if isStreaming { WorkingDots().scaleEffect(0.8) }
                Spacer()
                CopyButton(text: { code }, label: "Copy")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            Divider().overlay(Palette.border)
            ScrollView(.horizontal, showsIndicators: hovering) {
                Text(SyntaxHighlighter.highlight(code, language: language, theme: theme))
                    .font(theme.mono(12.5))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(12)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .card(fill: Palette.code)
        .onHover { hovering = $0 }
    }
}

/// A tiny, language-agnostic highlighter: comments, strings, numbers, keywords.
enum SyntaxHighlighter {
    static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "guard", "return", "for", "while", "in", "switch", "case", "default",
        "struct", "class", "enum", "protocol", "extension", "import", "public", "private", "internal", "static",
        "async", "await", "throws", "throw", "try", "catch", "do", "self", "Self", "nil", "true", "false", "init",
        "const", "function", "export", "from", "type", "interface", "new", "this", "null", "undefined", "def",
        "elif", "pass", "lambda", "None", "True", "False", "with", "as", "fn", "mut", "impl", "pub", "use", "match",
        "package", "go", "defer", "select", "chan", "map", "echo", "then", "fi", "done", "esac", "export",
    ]

    static func highlight(_ code: String, language: String?, theme: Theme) -> AttributedString {
        var result = AttributedString(code)
        guard code.count < 40_000 else { return result }
        result.foregroundColor = Palette.textPrimary
        let keywordColor = theme.accentColor
        let stringColor = Palette.success
        let commentColor = Palette.textTertiary
        let numberColor = Palette.warning

        apply(#"\b\d+(\.\d+)?\b"#, color: numberColor, in: code, to: &result)
        apply(#"\b[A-Za-z_]+\b"#, color: keywordColor, in: code, to: &result) { keywords.contains($0) }
        apply(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`[^`]*`"#, color: stringColor, in: code, to: &result)
        let hashComments = ["python", "py", "bash", "sh", "zsh", "shell", "ruby", "rb", "yaml", "yml", "toml"].contains(language?.lowercased() ?? "")
        apply(hashComments ? #"#.*$"# : #"//.*$|/\*[\s\S]*?\*/"#, color: commentColor, in: code, to: &result, options: [.anchorsMatchLines])
        return result
    }

    private static func apply(
        _ pattern: String,
        color: Color,
        in code: String,
        to result: inout AttributedString,
        options: NSRegularExpression.Options = [],
        where predicate: ((String) -> Bool)? = nil
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let nsRange = NSRange(code.startIndex..., in: code)
        for match in regex.matches(in: code, range: nsRange) {
            guard let range = Range(match.range, in: code) else { continue }
            if let predicate, !predicate(String(code[range])) { continue }
            guard let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].foregroundColor = color
        }
    }
}
