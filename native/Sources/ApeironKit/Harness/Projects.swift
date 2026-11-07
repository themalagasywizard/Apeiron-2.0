import Foundation

/// A named project: the folders and files Apeiron works with, plus standing
/// instructions. Every chat in a project gets full access to its linked
/// folders and files.
public struct Project: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    /// Standing instructions added to the system prompt of every chat.
    public var instructions: String
    /// Linked folders and files, in the order the user added them.
    public var items: [ProjectItem]
    /// Permission mode new chats in this project start in.
    public var defaultMode: PermissionMode
    /// Model new chats in this project start with (nil uses the app default).
    public var defaultModelID: String?
    /// One of the app's accent names, used for the project's dot.
    public var colorName: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        instructions: String = "",
        items: [ProjectItem] = [],
        defaultMode: PermissionMode = .fullAccess,
        defaultModelID: String? = nil,
        colorName: String = "ember",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.items = items
        self.defaultMode = defaultMode
        self.defaultModelID = defaultModelID
        self.colorName = colorName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Tolerant decoding so new fields never drop saved projects.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled project"
        instructions = (try? c.decode(String.self, forKey: .instructions)) ?? ""
        items = (try? c.decode([ProjectItem].self, forKey: .items)) ?? []
        defaultMode = (try? c.decode(PermissionMode.self, forKey: .defaultMode)) ?? .fullAccess
        defaultModelID = try? c.decodeIfPresent(String.self, forKey: .defaultModelID)
        colorName = (try? c.decode(String.self, forKey: .colorName)) ?? "ember"
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }

    public var folders: [ProjectItem] { items.filter(\.isDirectory) }
    public var files: [ProjectItem] { items.filter { !$0.isDirectory } }

    /// The folder chats in this project run in: the first linked folder, or
    /// the folder holding the first linked file.
    public var primaryFolder: URL? {
        if let folder = folders.first { return folder.url }
        return files.first.map { $0.url.deletingLastPathComponent() }
    }

    /// Every linked folder and file except the primary folder itself.
    public func linkedRoots(excluding workspace: URL?) -> [URL] {
        let primary = workspace?.standardizedFileURL.path
        return items.map(\.url).filter { $0.standardizedFileURL.path != primary }
    }

    /// Adds paths, skipping ones already linked.
    public mutating func link(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !items.contains(where: { $0.path == path }) else { continue }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            items.append(ProjectItem(path: path, isDirectory: isDirectory.boolValue))
        }
    }
}

public struct ProjectItem: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var path: String
    public var isDirectory: Bool
    public var id: String { path }

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
    public var name: String { url.lastPathComponent }
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// What the system prompt says about a chat's project.
public struct ProjectBrief: Sendable, Equatable {
    public var name: String
    public var instructions: String
    public var folders: [String]
    public var files: [String]

    public init(name: String, instructions: String, folders: [String], files: [String]) {
        self.name = name
        self.instructions = instructions
        self.folders = folders
        self.files = files
    }

    public init(_ project: Project) {
        self.init(
            name: project.name,
            instructions: project.instructions,
            folders: project.folders.map(\.path),
            files: project.files.map(\.path)
        )
    }

    var promptSection: String {
        var text = """
        # Project: \(name)
        This chat belongs to the project “\(name)”. You have full read and write access to every folder and \
        file linked to it, wherever they live on disk. Use absolute paths for anything outside the workspace.
        """
        if !folders.isEmpty {
            text += "\n\nLinked folders:\n" + folders.map { "- \($0)" }.joined(separator: "\n")
        }
        if !files.isEmpty {
            text += "\n\nLinked files:\n" + files.map { "- \($0)" }.joined(separator: "\n")
        }
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            text += "\n\nProject instructions from the user (follow them):\n<project_instructions>\n\(trimmed)\n</project_instructions>"
        }
        return text
    }
}

/// Projects as one JSON file in the Apeiron config folder.
public final class ProjectStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? ProjectContext.userConfigDirectory.appendingPathComponent("projects.json")
        try? FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public func load() -> [Project] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Project].self, from: data)) ?? []
    }

    public func save(_ projects: [Project]) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(projects).write(to: fileURL, options: .atomic)
    }
}
