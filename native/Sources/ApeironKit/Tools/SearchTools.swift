import Foundation

enum WorkspaceWalker {
    /// Enumerates regular files under `root`, skipping heavy folders.
    static func files(under root: URL, limit: Int = 50_000) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if ListDirectoryTool.ignored.contains(name) { enumerator.skipDescendants() }
                continue
            }
            if values?.isRegularFile == true { result.append(url) }
            if result.count >= limit { break }
        }
        return result
    }
}

public struct GlobTool: AgentTool {
    public init() {}
    public let name = "glob"
    public let category = ToolCategory.read
    public let description = """
    Find files by glob pattern, e.g. "**/*.swift" or "src/**/*.{ts,tsx}". Results are paths \
    relative to the search root, most recently modified first (max 200).
    """
    public var inputSchema: JSONValue {
        schema([
            "pattern": prop("string", "Glob pattern."),
            "path": prop("string", "Directory to search (default: workspace root)."),
        ], required: ["pattern"])
    }

    public func title(for input: JSONValue) -> String { "Find \(input["pattern"]?.stringValue ?? "files")" }
    public func permissionSubject(for input: JSONValue) -> String? { input["path"]?.stringValue ?? "." }
    public func touchedPaths(for input: JSONValue, context: ToolContext) -> [URL] {
        [context.resolve(input["path"]?.stringValue ?? ".")]
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let root = context.resolve(input["path"]?.stringValue ?? ".")
        let pattern = GlobPattern(input["pattern"]?.stringValue ?? "**/*")
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var matches: [(String, Date)] = []
        for url in WorkspaceWalker.files(under: root) {
            let relative = url.standardizedFileURL.path.replacingOccurrences(of: rootPath, with: "", options: .anchored)
            if pattern.matches(relative) {
                let date = FileStateTracker.modificationDate(url) ?? .distantPast
                matches.append((relative, date))
            }
        }
        matches.sort { $0.1 > $1.1 }
        if matches.isEmpty { return ToolOutput("(no files matched \(pattern.pattern))") }
        var lines = matches.prefix(200).map(\.0)
        if matches.count > 200 { lines.append("(\(matches.count - 200) more not shown; narrow the pattern)") }
        return ToolOutput(lines.joined(separator: "\n"))
    }
}

public struct GrepTool: AgentTool {
    public init() {}
    public let name = "grep"
    public let category = ToolCategory.read
    public let description = """
    Search file contents with a regular expression (ripgrep syntax when available). \
    output_mode: "files" (default, matching file paths), "content" (matching lines with line \
    numbers) or "count". Filter files with glob, e.g. "*.swift".
    """
    public var inputSchema: JSONValue {
        schema([
            "pattern": prop("string", "Regular expression to search for."),
            "path": prop("string", "File or directory to search (default: workspace root)."),
            "glob": prop("string", "Only search files matching this glob, e.g. \"*.ts\"."),
            "output_mode": ["type": "string", "enum": ["files", "content", "count"], "description": "What to return."],
            "case_insensitive": prop("boolean", "Ignore case."),
            "context": prop("integer", "Lines of context around matches (content mode)."),
            "max_results": prop("integer", "Maximum lines to return (default 250)."),
        ], required: ["pattern"])
    }

    public func title(for input: JSONValue) -> String { "Search “\(input["pattern"]?.stringValue ?? "")”" }
    public func permissionSubject(for input: JSONValue) -> String? { input["path"]?.stringValue ?? "." }
    public func touchedPaths(for input: JSONValue, context: ToolContext) -> [URL] {
        [context.resolve(input["path"]?.stringValue ?? ".")]
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let pattern = input["pattern"]?.stringValue ?? ""
        let root = context.resolve(input["path"]?.stringValue ?? ".")
        let mode = input["output_mode"]?.stringValue ?? "files"
        let insensitive = input["case_insensitive"]?.boolValue ?? false
        let contextLines = max(0, min(input["context"]?.intValue ?? 0, 10))
        let maxResults = max(1, min(input["max_results"]?.intValue ?? 250, 2000))
        let glob = input["glob"]?.stringValue

        if let rg = Shell.which("rg") {
            var args = [rg, "--color=never", "--no-heading", "--max-columns=400"]
            switch mode {
            case "content": args += ["-n"] + (contextLines > 0 ? ["-C", "\(contextLines)"] : [])
            case "count": args += ["-c"]
            default: args += ["-l"]
            }
            if insensitive { args.append("-i") }
            if let glob { args += ["-g", glob] }
            args += ["-e", pattern, "--", root.path]
            let command = args.map(Self.shellQuote).joined(separator: " ")
            let result = try await Shell.run(command, in: context.workspace, timeout: 60)
            if result.exitCode == 1 { return ToolOutput("(no matches)") }
            if result.exitCode > 1 { return .error(result.stderr.isEmpty ? "ripgrep failed" : result.stderr) }
            let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            var lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true).map {
                String($0).replacingOccurrences(of: rootPrefix, with: "", options: .anchored)
            }
            let total = lines.count
            if total > maxResults { lines = Array(lines.prefix(maxResults)) + ["(\(total - maxResults) more results not shown)"] }
            return ToolOutput(lines.joined(separator: "\n"))
        }
        return try fallbackSearch(pattern: pattern, root: root, mode: mode, insensitive: insensitive, glob: glob, maxResults: maxResults)
    }

    private func fallbackSearch(pattern: String, root: URL, mode: String, insensitive: Bool, glob: String?, maxResults: Int) throws -> ToolOutput {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: insensitive ? [.caseInsensitive] : [])
        } catch {
            return .error("Invalid regular expression: \(error.localizedDescription)")
        }
        let globPattern = glob.map { GlobPattern($0.contains("/") ? $0 : "**/" + $0) }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        let files = isDirectory.boolValue ? WorkspaceWalker.files(under: root) : [root]
        var output: [String] = []
        for url in files {
            let relative = url.standardizedFileURL.path.replacingOccurrences(of: rootPath, with: "", options: .anchored)
            if let globPattern, !globPattern.matches(relative) { continue }
            guard let data = try? Data(contentsOf: url), data.count < 2_000_000, !TextUtils.isProbablyBinary(data) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            var count = 0
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    count += 1
                    if mode == "content" { output.append("\(relative):\(number + 1):\(line.prefix(400))") }
                    if mode == "files" { break }
                }
            }
            if count > 0 {
                if mode == "files" { output.append(relative) }
                if mode == "count" { output.append("\(relative):\(count)") }
            }
            if output.count >= maxResults { break }
        }
        return ToolOutput(output.isEmpty ? "(no matches)" : output.prefix(maxResults).joined(separator: "\n"))
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
