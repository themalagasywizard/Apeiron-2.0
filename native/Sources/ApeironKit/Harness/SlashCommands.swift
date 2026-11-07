import Foundation

public struct SlashCommandInfo: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var summary: String
    public var argumentHint: String?
    public var isCustom: Bool
}

public enum SlashAction: Equatable, Sendable {
    case prompt(String)
    case clear
    case compact(focus: String?)
    case setModel(String?)
    case setMode(PermissionMode?)
    case remember(String)
    case help
    case export
    case unknown(String)
}

public enum SlashCommands {
    public static let builtIn: [SlashCommandInfo] = [
        SlashCommandInfo(name: "help", summary: "Show commands and shortcuts", argumentHint: nil, isCustom: false),
        SlashCommandInfo(name: "clear", summary: "Start fresh in this session", argumentHint: nil, isCustom: false),
        SlashCommandInfo(name: "compact", summary: "Summarise the conversation to free context", argumentHint: "[focus]", isCustom: false),
        SlashCommandInfo(name: "model", summary: "Switch model", argumentHint: "<model>", isCustom: false),
        SlashCommandInfo(name: "mode", summary: "Switch permission mode", argumentHint: "ask | auto | plan | full", isCustom: false),
        SlashCommandInfo(name: "plan", summary: "Research read-only and propose a plan", argumentHint: "[task]", isCustom: false),
        SlashCommandInfo(name: "remember", summary: "Add a note to APEIRON.md project memory", argumentHint: "<note>", isCustom: false),
        SlashCommandInfo(name: "init", summary: "Write an APEIRON.md describing this project", argumentHint: nil, isCustom: false),
        SlashCommandInfo(name: "review", summary: "Review the uncommitted changes", argumentHint: nil, isCustom: false),
        SlashCommandInfo(name: "export", summary: "Export this conversation as Markdown", argumentHint: nil, isCustom: false),
    ]

    public static func all(custom: [CustomCommand]) -> [SlashCommandInfo] {
        builtIn + custom.map { SlashCommandInfo(name: $0.name, summary: $0.description, argumentHint: "[args]", isCustom: true) }
    }

    public static func isCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return false }
        let name = trimmed.dropFirst().prefix { !$0.isWhitespace }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" }
    }

    public static func parse(_ text: String, custom: [CustomCommand]) -> SlashAction {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace }).lowercased()
        let args = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let argument: String? = args.isEmpty ? nil : args

        switch name {
        case "help": return .help
        case "clear", "new": return .clear
        case "compact": return .compact(focus: argument)
        case "model": return .setModel(argument)
        case "export": return .export
        case "mode": return .setMode(argument.flatMap(mode(named:)))
        case "remember", "memory":
            guard let argument else { return .unknown("Usage: /remember <note>") }
            return .remember(argument)
        case "plan":
            if let argument { return .prompt("<system-reminder>The user wants a plan before any changes.</system-reminder>\n\(argument)") }
            return .setMode(.plan)
        case "init":
            return .prompt("""
            Explore this project and write an APEIRON.md file at the workspace root that will help an AI agent \
            work here. Cover: what the project is, how it's organised, how to build, run and test it, the \
            conventions it follows, and gotchas. Keep it concise and specific to this codebase. If APEIRON.md, \
            AGENTS.md or CLAUDE.md already exists, improve on it rather than starting over.
            """)
        case "review":
            return .prompt("""
            Review the uncommitted changes in this repository (use git diff and git status). Look for bugs, \
            missing edge cases, security problems and unclear code. Report findings ordered by severity with \
            file:line references, and say plainly if everything looks good.
            """)
        default:
            if let command = custom.first(where: { $0.name.lowercased() == name }) {
                return .prompt(command.template.replacingOccurrences(of: "$ARGUMENTS", with: args))
            }
            return .unknown("Unknown command /\(name). Type /help to see what's available.")
        }
    }

    public static func mode(named name: String) -> PermissionMode? {
        switch name.lowercased() {
        case "ask", "default", "normal": return .ask
        case "auto", "autoedit", "auto-edit", "edit", "edits": return .autoEdit
        case "plan", "read-only", "readonly": return .plan
        case "full", "fullaccess", "full-access", "yolo", "bypass": return .fullAccess
        default: return nil
        }
    }

    /// Appends a note to the project's APEIRON.md.
    public static func remember(_ note: String, workspace: URL) throws -> URL {
        let url = workspace.appendingPathComponent("APEIRON.md")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? "# Project memory\n"
        if !text.hasSuffix("\n") { text += "\n" }
        text += "- \(note)\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public static let helpText = """
    **Commands**
    \(builtIn.map { "- `/\($0.name)\($0.argumentHint.map { " \($0)" } ?? "")` – \($0.summary)" }.joined(separator: "\n"))

    Custom commands live in `.apeiron/commands/*.md` (project) or `~/.apeiron/commands/*.md`; `$ARGUMENTS` is replaced with what you type after the command.

    **Shortcuts**
    - ⌘K command palette · ⌘N new chat · ⌘O open folder
    - Return to send · ⇧Return or ⌥Return for a new line
    - Esc stops the agent · ⌘⇧M cycles the permission mode
    """
}
