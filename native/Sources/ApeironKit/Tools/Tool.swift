import Foundation

public enum ToolCategory: String, Codable, Sendable {
    /// Reads local state; safe to run in parallel and in plan mode.
    case read
    /// Changes files.
    case write
    /// Runs arbitrary commands.
    case execute
    /// Reaches the network.
    case network
    /// Harness bookkeeping (todos, skills, subagents).
    case meta

    public var isReadOnly: Bool { self == .read || self == .meta }
}

/// Extra structured data a tool returns for the UI.
public enum ToolMetadata: Codable, Hashable, Sendable {
    case diff(path: String, before: String, after: String)
    case todos([TodoItem])
    case command(command: String, exitCode: Int32, timedOut: Bool)
    case fileRead(path: String, lineCount: Int)
    case subagent(steps: Int)
}

public struct ToolOutput: Sendable {
    public var content: String
    public var isError: Bool
    public var metadata: ToolMetadata?

    public init(_ content: String, isError: Bool = false, metadata: ToolMetadata? = nil) {
        self.content = content
        self.isError = isError
        self.metadata = metadata
    }

    public static func error(_ message: String) -> ToolOutput {
        ToolOutput(message, isError: true)
    }
}

/// What the user sees in an approval prompt before a tool runs.
public enum ToolPreview: Hashable, Sendable, Codable {
    case command(String)
    case diff(path: String, before: String, after: String)
    case text(String)
}

public struct ToolInputError: Error, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: JSONValue { get }
    var category: ToolCategory { get }

    /// Short human title for cards, e.g. "Read Sources/App.swift".
    func title(for input: JSONValue) -> String
    /// The value permission rules match against, e.g. the command or path.
    func permissionSubject(for input: JSONValue) -> String?
    /// File paths the call would touch (for workspace boundary checks).
    func touchedPaths(for input: JSONValue, context: ToolContext) -> [URL]
    /// Optional preview shown when asking for approval.
    func preview(for input: JSONValue, context: ToolContext) async -> ToolPreview?
    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput
}

public extension AgentTool {
    func permissionSubject(for input: JSONValue) -> String? { nil }
    func touchedPaths(for input: JSONValue, context: ToolContext) -> [URL] { [] }
    func preview(for input: JSONValue, context: ToolContext) async -> ToolPreview? { nil }

    var spec: ToolSpec { ToolSpec(name: name, description: description, inputSchema: inputSchema) }

    /// Validates required properties declared in the schema.
    func validate(_ input: JSONValue) -> String? {
        guard input.objectValue != nil else { return "Input must be a JSON object." }
        let required = inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let missing = required.filter { input[$0] == nil || input[$0]?.isNull == true }
        if !missing.isEmpty {
            return "Missing required parameter(s): \(missing.joined(separator: ", "))."
        }
        return nil
    }
}

/// Builds a JSON schema object.
public func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
    [
        "type": "object",
        "properties": .object(properties),
        "required": .array(required.map { .string($0) }),
        "additionalProperties": false,
    ]
}

public func prop(_ type: String, _ description: String) -> JSONValue {
    ["type": .string(type), "description": .string(description)]
}

/// Tracks which files the agent has read and when, so writes can refuse to
/// clobber files the model hasn't seen or that changed underneath it.
public actor FileStateTracker {
    private var readTimes: [String: Date] = [:]

    public init() {}

    public func markRead(_ url: URL) {
        readTimes[url.standardizedFileURL.path] = Self.modificationDate(url) ?? Date()
    }

    public func markWritten(_ url: URL) {
        readTimes[url.standardizedFileURL.path] = Self.modificationDate(url) ?? Date()
    }

    /// nil when writing is allowed, otherwise the reason it isn't.
    public func checkWritable(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let readAt = readTimes[path] else {
            return "You must read \(url.lastPathComponent) with read_file before changing it."
        }
        if let modified = Self.modificationDate(url), modified.timeIntervalSince(readAt) > 0.5 {
            return "\(url.lastPathComponent) changed on disk since you last read it. Read it again before editing."
        }
        return nil
    }

    public func reset() { readTimes = [:] }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Holds the agent's todo list.
public actor TodoStore {
    public private(set) var items: [TodoItem] = []
    public init(items: [TodoItem] = []) { self.items = items }
    public func replace(_ items: [TodoItem]) { self.items = items }
}

/// Everything a tool may need from the running session.
public final class ToolContext: @unchecked Sendable {
    public let workspace: URL
    public let sessionDirectory: URL
    public let files: FileStateTracker
    public let todos: TodoStore
    public let skills: [Skill]
    /// Extra folders and files linked to the session's project. The agent has
    /// the same access to them as to the workspace itself.
    public let linkedRoots: [URL]
    /// Runs a child agent for the `task` tool; set by the harness.
    public var subagentRunner: (@Sendable (_ description: String, _ prompt: String, _ readOnly: Bool) async throws -> (String, Int))?

    public init(
        workspace: URL,
        sessionDirectory: URL,
        files: FileStateTracker = FileStateTracker(),
        todos: TodoStore = TodoStore(),
        skills: [Skill] = [],
        linkedRoots: [URL] = []
    ) {
        self.workspace = workspace.standardizedFileURL
        self.linkedRoots = linkedRoots.map(\.standardizedFileURL)
        self.sessionDirectory = sessionDirectory
        self.files = files
        self.todos = todos
        self.skills = skills
    }

    /// Resolves a path argument relative to the workspace, expanding `~`.
    public func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return workspace.appendingPathComponent(expanded).standardizedFileURL
    }

    /// True inside the workspace or any folder or file linked to the project.
    public func isInsideWorkspace(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return ([workspace] + linkedRoots).contains { Self.path(path, isInside: $0) }
    }

    static func path(_ path: String, isInside root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        if path == rootPath { return true }
        return path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    /// Reads that never need approval: the workspace, this session's own
    /// files (saved tool output) and skill folders.
    public func isFreelyReadable(_ url: URL) -> Bool {
        if isInsideWorkspace(url) { return true }
        let path = url.standardizedFileURL.path
        let roots = [sessionDirectory] + skills.map(\.directory)
        return roots.contains { root in
            let rootPath = root.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
    }

    /// Path shown to the user and model: relative inside the workspace.
    public func displayPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let root = workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
        if path.hasPrefix(root) { return String(path.dropFirst(root.count)) }
        if path == workspace.path { return "." }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}
