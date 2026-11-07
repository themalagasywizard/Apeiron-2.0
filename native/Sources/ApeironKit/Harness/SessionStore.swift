import Foundation

/// A persisted conversation.
public struct Session: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var workspacePath: String?
    public var modelID: String
    public var mode: PermissionMode
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var usage: Usage
    public var todos: [TodoItem]
    public var isPinned: Bool

    public init(
        id: UUID = UUID(),
        title: String = "New chat",
        workspacePath: String? = nil,
        modelID: String,
        mode: PermissionMode = .ask,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = [],
        usage: Usage = .zero,
        todos: [TodoItem] = [],
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.workspacePath = workspacePath
        self.modelID = modelID
        self.mode = mode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.usage = usage
        self.todos = todos
        self.isPinned = isPinned
    }

    public var summary: SessionSummary {
        SessionSummary(id: id, title: title, workspacePath: workspacePath, modelID: modelID, updatedAt: updatedAt, isPinned: isPinned)
    }

    /// A title from the first prompt.
    public static func title(from prompt: String) -> String {
        let line = prompt
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return "New chat" }
        if line.count <= 52 { return line }
        let cut = line.prefix(52)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 30 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }
}

public struct SessionSummary: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var workspacePath: String?
    public var modelID: String
    public var updatedAt: Date
    public var isPinned: Bool
}

/// Sessions as JSON files with a small index for fast listing.
public final class SessionStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL? = nil) {
        self.directory = directory ?? ProjectContext.userConfigDirectory.appendingPathComponent("sessions")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Folder for a session's spilled tool output and subagent files.
    public func workingDirectory(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func list() -> [SessionSummary] {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? Data(contentsOf: indexURL), let index = try? decoder.decode([SessionSummary].self, from: data) {
            return index.sorted { $0.updatedAt > $1.updatedAt }
        }
        let rebuilt = rebuildIndexLocked()
        return rebuilt.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(_ id: UUID) -> Session? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? decoder.decode(Session.self, from: data)
    }

    public func save(_ session: Session) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try encoder.encode(session)
        try data.write(to: fileURL(for: session.id), options: .atomic)
        var index = (try? decoder.decode([SessionSummary].self, from: Data(contentsOf: indexURL))) ?? []
        index.removeAll { $0.id == session.id }
        index.append(session.summary)
        try encoder.encode(index).write(to: indexURL, options: .atomic)
    }

    public func delete(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(for: id))
        try? FileManager.default.removeItem(at: workingDirectory(for: id))
        var index = (try? decoder.decode([SessionSummary].self, from: Data(contentsOf: indexURL))) ?? []
        index.removeAll { $0.id == id }
        try? encoder.encode(index).write(to: indexURL, options: .atomic)
    }

    /// Exports a session as Markdown.
    public func markdown(for session: Session) -> String {
        var output = "# \(session.title)\n\n"
        for message in session.messages {
            switch message.role {
            case .user:
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty && message.kind == .normal {
                    output += "## You\n\n\(stripReminders(text))\n\n"
                }
            case .assistant:
                output += "## Apeiron\n\n"
                for block in message.blocks {
                    switch block {
                    case .text(let text): output += text + "\n\n"
                    case .toolCall(let call): output += "> 🔧 `\(call.name)` \(call.input.serialized())\n\n"
                    default: break
                    }
                }
            }
        }
        return output
    }

    private func rebuildIndexLocked() -> [SessionSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let summaries = files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }.compactMap { url -> SessionSummary? in
            guard let data = try? Data(contentsOf: url), let session = try? decoder.decode(Session.self, from: data) else { return nil }
            return session.summary
        }
        try? encoder.encode(summaries).write(to: indexURL, options: .atomic)
        return summaries
    }
}

/// Removes `<system-reminder>` blocks the harness attaches to user messages.
public func stripReminders(_ text: String) -> String {
    text.replacingOccurrences(of: "(?s)<system-reminder>.*?</system-reminder>", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
