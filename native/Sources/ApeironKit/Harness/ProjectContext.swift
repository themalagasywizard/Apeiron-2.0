import Foundation

/// A skill: a folder with a SKILL.md (front matter `name`, `description`).
/// Only name and description go in the system prompt; the body loads on demand.
public struct Skill: Hashable, Sendable, Identifiable {
    public var id: String { directory.path }
    public var name: String
    public var description: String
    public var body: String
    public var directory: URL
}

/// A custom slash command from a Markdown file. `$ARGUMENTS` is replaced
/// with whatever follows the command.
public struct CustomCommand: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var template: String
}

/// A memory file loaded into every session (APEIRON.md, AGENTS.md, CLAUDE.md).
public struct MemoryFile: Hashable, Sendable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    public var scope: String
    public var content: String
}

/// `.apeiron/settings.json` (project) merged over `~/.apeiron/settings.json` (user).
public struct HarnessSettings: Codable, Sendable, Equatable {
    public var permissions: PermissionRules
    public var hooks: [HookDefinition]

    public init(permissions: PermissionRules = PermissionRules(), hooks: [HookDefinition] = []) {
        self.permissions = permissions
        self.hooks = hooks
    }

    public static func merged(_ layers: [HarnessSettings]) -> HarnessSettings {
        var result = HarnessSettings()
        for layer in layers {
            result.permissions.allow += layer.permissions.allow
            result.permissions.deny += layer.permissions.deny
            result.hooks += layer.hooks
        }
        return result
    }
}

/// Everything the harness discovers about a workspace at session start.
public struct ProjectContext: Sendable {
    public var workspace: URL
    public var memory: [MemoryFile]
    public var skills: [Skill]
    public var commands: [CustomCommand]
    public var settings: HarnessSettings
    public var gitBranch: String?
    public var gitStatusSummary: String?

    public static var userConfigDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["APEIRON_HOME"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".apeiron")
    }

    public static func load(workspace: URL, includeGit: Bool = true) async -> ProjectContext {
        let workspace = workspace.standardizedFileURL
        let user = userConfigDirectory
        let project = workspace.appendingPathComponent(".apeiron")

        var memory: [MemoryFile] = []
        let candidates: [(URL, String)] = [
            (user.appendingPathComponent("APEIRON.md"), "user"),
            (workspace.appendingPathComponent("APEIRON.md"), "project"),
            (workspace.appendingPathComponent("AGENTS.md"), "project"),
            (workspace.appendingPathComponent("CLAUDE.md"), "project"),
            (project.appendingPathComponent("APEIRON.local.md"), "local"),
        ]
        for (url, scope) in candidates {
            if let content = try? String(contentsOf: url, encoding: .utf8),
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                memory.append(MemoryFile(url: url, scope: scope, content: TextUtils.truncateMiddle(content, maxCharacters: 40_000)))
            }
        }

        var skills: [Skill] = []
        for root in [project.appendingPathComponent("skills"), workspace.appendingPathComponent(".claude/skills"), user.appendingPathComponent("skills")] {
            skills += loadSkills(in: root)
        }
        var seen = Set<String>()
        skills = skills.filter { seen.insert($0.name.lowercased()).inserted }

        var commands: [CustomCommand] = []
        for root in [project.appendingPathComponent("commands"), user.appendingPathComponent("commands")] {
            commands += loadCommands(in: root)
        }

        let layers = [user.appendingPathComponent("settings.json"), project.appendingPathComponent("settings.json")]
            .compactMap { url -> HarnessSettings? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(HarnessSettings.self, from: data)
            }

        var branch: String?
        var status: String?
        if includeGit, FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".git").path) {
            if let result = try? await Shell.run("git rev-parse --abbrev-ref HEAD", in: workspace, timeout: 5), result.exitCode == 0 {
                branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let result = try? await Shell.run("git status --short | head -n 30", in: workspace, timeout: 5), result.exitCode == 0 {
                let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                status = trimmed.isEmpty ? "clean" : trimmed
            }
        }

        return ProjectContext(
            workspace: workspace,
            memory: memory,
            skills: skills,
            commands: commands,
            settings: HarnessSettings.merged(layers),
            gitBranch: branch,
            gitStatusSummary: status
        )
    }

    static func loadSkills(in root: URL) -> [Skill] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { directory in
            let file = directory.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let (meta, body) = parseFrontMatter(text)
            return Skill(
                name: meta["name"] ?? directory.lastPathComponent,
                description: meta["description"] ?? String(body.prefix(160)),
                body: body,
                directory: directory
            )
        }.sorted { $0.name < $1.name }
    }

    static func loadCommands(in root: URL) -> [CustomCommand] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return entries.filter { $0.pathExtension == "md" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let (meta, body) = parseFrontMatter(text)
            let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
            return CustomCommand(
                name: url.deletingPathExtension().lastPathComponent,
                description: meta["description"] ?? String(firstLine.prefix(80)),
                template: body
            )
        }.sorted { $0.name < $1.name }
    }

    /// Minimal YAML front matter: `key: value` lines between `---` fences.
    public static func parseFrontMatter(_ text: String) -> ([String: String], String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], text)
        }
        var meta: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            meta[key] = value
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (meta, body)
    }
}
