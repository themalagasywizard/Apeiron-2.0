import Foundation

public struct ReadFileTool: AgentTool {
    public init() {}
    public let name = "read_file"
    public let category = ToolCategory.read
    public let description = """
    Read a text file from the local filesystem. Returns lines prefixed with their line numbers \
    (the prefix is not part of the file). Reads up to 2000 lines by default; use offset and limit \
    to page through larger files. Always read a file before editing or overwriting it. \
    Paths may be relative to the workspace.
    """
    public var inputSchema: JSONValue {
        schema([
            "path": prop("string", "File path, absolute or relative to the workspace."),
            "offset": prop("integer", "1-based line to start from."),
            "limit": prop("integer", "Maximum number of lines to return (default 2000)."),
        ], required: ["path"])
    }

    public func title(for input: JSONValue) -> String {
        "Read \(input["path"]?.stringValue ?? "file")"
    }

    public func permissionSubject(for input: JSONValue) -> String? { input["path"]?.stringValue }

    public func touchedPaths(for input: JSONValue, context: ToolContext) -> [URL] {
        input["path"]?.stringValue.map { [context.resolve($0)] } ?? []
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = context.resolve(input["path"]?.stringValue ?? "")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .error("File not found: \(context.displayPath(url)). Use glob or list_directory to find the right path.")
        }
        if isDirectory.boolValue {
            return .error("\(context.displayPath(url)) is a directory. Use list_directory instead.")
        }
        let data = try Data(contentsOf: url)
        if TextUtils.isProbablyBinary(data) {
            return .error("\(context.displayPath(url)) looks like a binary file (\(data.count) bytes); not shown.")
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        let offset = max(1, input["offset"]?.intValue ?? 1)
        let limit = max(1, min(input["limit"]?.intValue ?? 2000, 5000))
        await context.files.markRead(url)

        if text.isEmpty {
            return ToolOutput("(empty file)", metadata: .fileRead(path: context.displayPath(url), lineCount: 0))
        }
        guard offset <= lines.count else {
            return .error("Offset \(offset) is past the end of the file (\(lines.count) lines).")
        }
        let end = min(lines.count, offset - 1 + limit)
        var output = ""
        output.reserveCapacity(min(text.utf8.count, 200_000))
        for number in offset...end {
            var line = lines[number - 1]
            if line.count > 2000 { line = String(line.prefix(2000)) + "… [line truncated]" }
            output += String(format: "%6d\t", number) + line + "\n"
        }
        if end < lines.count {
            output += "\n[Showing lines \(offset)-\(end) of \(lines.count). Use offset=\(end + 1) to continue.]"
        }
        return ToolOutput(output, metadata: .fileRead(path: context.displayPath(url), lineCount: lines.count))
    }
}

public struct WriteFileTool: AgentTool {
    public init() {}
    public let name = "write_file"
    public let category = ToolCategory.write
    public let description = """
    Create a new file or completely replace an existing one. Prefer edit_file for changes to \
    existing files. Overwriting an existing file requires reading it first. Parent directories \
    are created as needed.
    """
    public var inputSchema: JSONValue {
        schema([
            "path": prop("string", "File path, absolute or relative to the workspace."),
            "content": prop("string", "The full file content."),
        ], required: ["path", "content"])
    }

    public func title(for input: JSONValue) -> String { "Write \(input["path"]?.stringValue ?? "file")" }
    public func permissionSubject(for input: JSONValue) -> String? { input["path"]?.stringValue }
    public func touchedPaths(for input: JSONValue, context: ToolContext) -> [URL] {
        input["path"]?.stringValue.map { [context.resolve($0)] } ?? []
    }

    public func preview(for input: JSONValue, context: ToolContext) async -> ToolPreview? {
        let url = context.resolve(input["path"]?.stringValue ?? "")
        let before = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return .diff(path: context.displayPath(url), before: before, after: input["content"]?.stringValue ?? "")
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = context.resolve(input["path"]?.stringValue ?? "")
        let content = input["content"]?.stringValue ?? ""
        if let problem = await context.files.checkWritable(url) { return .error(problem) }
        let before = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let existed = FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        await context.files.markWritten(url)
        let lineCount = content.isEmpty ? 0 : content.components(separatedBy: "\n").count
        let verb = existed ? "Updated" : "Created"
        return ToolOutput(
            "\(verb) \(context.displayPath(url)) (\(lineCount) lines).",
            metadata: .diff(path: context.displayPath(url), before: before, after: content)
        )
    }
}

public struct EditFileTool: AgentTool {
    public init() {}
    public let name = "edit_file"
    public let category = ToolCategory.write
    public let description = """
    Replace an exact string in a file. old_string must match the file exactly (including \
    whitespace and indentation, without line-number prefixes) and must be unique unless \
    replace_all is true; include surrounding lines to make it unique. Read the file first. \
    To create a file, use write_file.
    """
    public var inputSchema: JSONValue {
        schema([
            "path": prop("string", "File path, absolute or relative to the workspace."),
            "old_string": prop("string", "Exact text to replace."),
            "new_string": prop("string", "Replacement text (must differ from old_string)."),
            "replace_all": prop("boolean", "Replace every occurrence (default false)."),
        ], required: ["path", "old_string", "new_string"])
    }

    public func title(for input: JSONValue) -> String { "Edit \(input["path"]?.stringValue ?? "file")" }
    public func permissionSubject(for input: JSONValue) -> String? { input["path"]?.stringValue }
    public func touchedPaths(for input: JSONValue, context: ToolContext) -> [URL] {
        input["path"]?.stringValue.map { [context.resolve($0)] } ?? []
    }

    public func preview(for input: JSONValue, context: ToolContext) async -> ToolPreview? {
        let url = context.resolve(input["path"]?.stringValue ?? "")
        guard let before = try? String(contentsOf: url, encoding: .utf8),
              case .success(let after) = Self.apply(input, to: before) else { return nil }
        return .diff(path: context.displayPath(url), before: before, after: after)
    }

    static func apply(_ input: JSONValue, to text: String) -> Result<String, ToolInputError> {
        let old = input["old_string"]?.stringValue ?? ""
        let new = input["new_string"]?.stringValue ?? ""
        let replaceAll = input["replace_all"]?.boolValue ?? false
        guard !old.isEmpty else { return .failure(ToolInputError("old_string is empty. Use write_file to create files.")) }
        guard old != new else { return .failure(ToolInputError("old_string and new_string are identical; nothing to change.")) }
        let occurrences = text.components(separatedBy: old).count - 1
        if occurrences == 0 {
            let trimmed = old.trimmingCharacters(in: .whitespacesAndNewlines)
            let hint = !trimmed.isEmpty && text.contains(trimmed)
                ? " A version with different surrounding whitespace exists; copy the exact text from read_file output."
                : " Read the file again and copy the exact text."
            return .failure(ToolInputError("old_string was not found in the file.\(hint)"))
        }
        if occurrences > 1 && !replaceAll {
            return .failure(ToolInputError("old_string appears \(occurrences) times. Add surrounding context to make it unique, or set replace_all to true."))
        }
        if replaceAll {
            return .success(text.replacingOccurrences(of: old, with: new))
        }
        guard let range = text.range(of: old) else { return .failure(ToolInputError("old_string was not found.")) }
        return .success(text.replacingCharacters(in: range, with: new))
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = context.resolve(input["path"]?.stringValue ?? "")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .error("File not found: \(context.displayPath(url)). Use write_file to create it.")
        }
        if let problem = await context.files.checkWritable(url) { return .error(problem) }
        let before = try String(contentsOf: url, encoding: .utf8)
        switch Self.apply(input, to: before) {
        case .failure(let error):
            return .error(error.message)
        case .success(let after):
            try after.write(to: url, atomically: true, encoding: .utf8)
            await context.files.markWritten(url)
            let stats = LineDiff.stats(before: before, after: after)
            return ToolOutput(
                "Edited \(context.displayPath(url)) (+\(stats.added) −\(stats.removed)).",
                metadata: .diff(path: context.displayPath(url), before: before, after: after)
            )
        }
    }
}

public struct ListDirectoryTool: AgentTool {
    public init() {}
    public let name = "list_directory"
    public let category = ToolCategory.read
    public let description = "List the entries of a directory (directories end with /). Skips .git, node_modules and build folders."
    public var inputSchema: JSONValue {
        schema(["path": prop("string", "Directory path (default: workspace root).")])
    }

    static let ignored: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".DS_Store", "Pods", ".swiftpm", "dist", "build", ".next", "__pycache__", ".venv", "target"]

    public func title(for input: JSONValue) -> String { "List \(input["path"]?.stringValue ?? ".")" }
    public func permissionSubject(for input: JSONValue) -> String? { input["path"]?.stringValue ?? "." }
    public func touchedPaths(for input: JSONValue, context: ToolContext) -> [URL] {
        [context.resolve(input["path"]?.stringValue ?? ".")]
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = context.resolve(input["path"]?.stringValue ?? ".")
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
        } catch {
            throw FileAccessError(url: url, underlying: error)
        }
        var lines: [String] = []
        var skipped = 0
        for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = entry.lastPathComponent
            if Self.ignored.contains(name) { skipped += 1; continue }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                lines.append(name + "/")
            } else {
                let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
                lines.append("\(name)  \(size)")
            }
        }
        if lines.count > 500 { lines = Array(lines.prefix(500)) + ["… \(lines.count - 500) more"] }
        var output = "\(context.displayPath(url))/\n" + lines.map { "  " + $0 }.joined(separator: "\n")
        if skipped > 0 { output += "\n  (\(skipped) ignored: build/vendor/VCS folders)" }
        return ToolOutput(output)
    }
}
