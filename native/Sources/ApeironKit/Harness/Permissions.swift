import Foundation

/// How much the agent may do without asking.
public enum PermissionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Reads run freely; edits, commands and network ask first.
    case ask
    /// Edits inside the workspace run freely; commands and network ask.
    case autoEdit
    /// Read-only: the agent investigates and proposes a plan.
    case plan
    /// Everything runs, except commands flagged as risky.
    case fullAccess

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ask: return "Ask first"
        case .autoEdit: return "Auto-edit"
        case .plan: return "Plan"
        case .fullAccess: return "Full access"
        }
    }

    public var symbol: String {
        switch self {
        case .ask: return "hand.raised"
        case .autoEdit: return "pencil.and.outline"
        case .plan: return "map"
        case .fullAccess: return "bolt"
        }
    }

    public var summary: String {
        switch self {
        case .ask: return "Asks before edits, commands and web requests"
        case .autoEdit: return "Edits files freely, asks before commands"
        case .plan: return "Read-only research, then a plan"
        case .fullAccess: return "Runs everything except risky commands"
        }
    }
}

/// A rule such as `bash`, `bash(git status)`, `bash(npm run test:*)`,
/// `edit_file(src/**)` or `web_fetch(domain:github.com)`.
public struct PermissionRule: Codable, Hashable, Sendable, CustomStringConvertible {
    public var tool: String
    public var pattern: String?

    public init(tool: String, pattern: String? = nil) {
        self.tool = tool
        self.pattern = pattern
    }

    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") {
            tool = String(trimmed[..<open])
            pattern = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        } else {
            tool = trimmed
            pattern = nil
        }
    }

    public var description: String {
        pattern.map { "\(tool)(\($0))" } ?? tool
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let rule = PermissionRule(parsing: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Empty rule"))
        }
        self = rule
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public func matches(tool name: String, subject: String?) -> Bool {
        guard tool == name || tool == "*" else { return false }
        guard let pattern, !pattern.isEmpty, pattern != "*" else { return true }
        guard let subject else { return false }
        if pattern.hasSuffix(":*") {
            return subject.hasPrefix(String(pattern.dropLast(2)))
        }
        if pattern.contains("*") || pattern.contains("?") {
            return GlobPattern(pattern).matches(subject)
        }
        return subject == pattern
    }

    /// The rule offered by "Always allow" for a call.
    public static func suggested(tool: String, category: ToolCategory, subject: String?) -> PermissionRule {
        switch category {
        case .execute:
            guard let subject, !subject.isEmpty else { return PermissionRule(tool: tool) }
            // Allow the command's first word(s) as a prefix, e.g. "npm run test:*".
            let words = subject.split(separator: " ").prefix(2).joined(separator: " ")
            let prefix = subject.contains("&&") || subject.contains("|") || subject.contains(";") ? subject : words
            return PermissionRule(tool: tool, pattern: prefix == subject ? subject : prefix + ":*")
        case .network:
            return PermissionRule(tool: tool, pattern: subject)
        default:
            return PermissionRule(tool: tool)
        }
    }
}

public struct PermissionRules: Codable, Sendable, Equatable {
    public var allow: [PermissionRule]
    public var deny: [PermissionRule]

    public init(allow: [PermissionRule] = [], deny: [PermissionRule] = []) {
        self.allow = allow
        self.deny = deny
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allow = try container.decodeIfPresent([PermissionRule].self, forKey: .allow) ?? []
        deny = try container.decodeIfPresent([PermissionRule].self, forKey: .deny) ?? []
    }
}

public enum PermissionDecision: Equatable, Sendable {
    case allow
    case ask(reason: String?)
    case deny(reason: String)
}

/// Guards against commands that are never OK, and flags ones that always
/// deserve a human look.
public enum CommandSafety {
    static let catastrophic: [String] = [
        #"rm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)+(--no-preserve-root\s+)?(/|~|\$HOME)(\s|$|/\*)"#,
        #":\(\)\s*\{\s*:\|:&\s*\};:"#,
        #"\bmkfs(\.\w+)?\b"#,
        #"\bdd\s+.*of=/dev/(disk|sd|nvme|rdisk)"#,
        #"chmod\s+-R\s+0?777\s+/(\s|$)"#,
        #">\s*/dev/(disk|sd|nvme|rdisk)"#,
    ]

    static let risky: [String] = [
        #"\brm\s+-[a-zA-Z]*r"#,
        #"\bsudo\b"#,
        #"\bgit\s+push\b.*(--force|-f\b|--force-with-lease)"#,
        #"\bgit\s+reset\s+--hard\b"#,
        #"\bgit\s+clean\s+-[a-zA-Z]*f"#,
        #"\bgit\s+push\b.*\b(main|master)\b"#,
        #"(curl|wget)\b[^|]*\|\s*(ba|z)?sh\b"#,
        #"\b(shutdown|reboot|halt)\b"#,
        #"\bkillall\b"#,
        #"\bdrop\s+(table|database)\b"#,
    ]

    public static func isCatastrophic(_ command: String) -> Bool {
        catastrophic.contains { command.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    public static func isRisky(_ command: String) -> Bool {
        risky.contains { command.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}

/// Decides whether a tool call runs, asks, or is refused.
public struct PermissionPolicy: Sendable, Equatable {
    public var mode: PermissionMode
    public var rules: PermissionRules

    public init(mode: PermissionMode = .ask, rules: PermissionRules = PermissionRules()) {
        self.mode = mode
        self.rules = rules
    }

    public func evaluate(tool: AgentTool, input: JSONValue, context: ToolContext) -> PermissionDecision {
        let subject = tool.permissionSubject(for: input)
        if let rule = rules.deny.first(where: { $0.matches(tool: tool.name, subject: subject) }) {
            return .deny(reason: "Blocked by the rule \(rule).")
        }

        if tool.category == .execute, let command = subject {
            if CommandSafety.isCatastrophic(command) {
                return .deny(reason: "This command could destroy data outside the project and is always blocked.")
            }
        }

        if mode == .plan {
            switch tool.category {
            case .read, .meta:
                break
            case .network:
                return .ask(reason: "Plan mode: fetching from the web needs approval.")
            case .write, .execute:
                return .deny(reason: "Plan mode is on, so nothing can be changed. Finish researching and present your plan; the user will switch modes to let you implement it.")
            }
        }

        let paths = tool.touchedPaths(for: input, context: context)
        let outside = paths.filter {
            tool.category.isReadOnly ? !context.isFreelyReadable($0) : !context.isInsideWorkspace($0)
        }
        let risky = tool.category == .execute && CommandSafety.isRisky(subject ?? "")

        if rules.allow.contains(where: { $0.matches(tool: tool.name, subject: subject) }) && !risky {
            return .allow
        }

        switch tool.category {
        case .read, .meta:
            if !outside.isEmpty && mode != .fullAccess {
                return .ask(reason: "Reads \(outside.first.map { context.displayPath($0) } ?? "a path") outside the workspace.")
            }
            return .allow
        case .write:
            if !outside.isEmpty {
                return mode == .fullAccess ? .allow : .ask(reason: "Writes outside the workspace.")
            }
            return (mode == .autoEdit || mode == .fullAccess) ? .allow : .ask(reason: nil)
        case .execute:
            if risky { return .ask(reason: "This command is flagged as potentially destructive.") }
            return mode == .fullAccess ? .allow : .ask(reason: nil)
        case .network:
            return mode == .fullAccess ? .allow : .ask(reason: nil)
        }
    }
}

public struct PermissionRequest: Identifiable, Sendable, Hashable {
    public var id: String { toolCall.id }
    public var toolCall: ToolCall
    public var toolName: String
    public var category: ToolCategory
    public var title: String
    public var subject: String?
    public var reason: String?
    public var preview: ToolPreview?
    public var suggestedRule: PermissionRule
}

public enum PermissionReply: Sendable, Equatable {
    case allowOnce
    case allowAlways(PermissionRule)
    case deny(feedback: String?)
}

/// Implemented by the UI (or CLI) to ask the human.
public protocol PermissionPrompter: Sendable {
    func requestPermission(_ request: PermissionRequest) async -> PermissionReply
}

/// Approves everything – for tests and headless runs in full-access mode.
public struct AutoApprovePrompter: PermissionPrompter {
    public init() {}
    public func requestPermission(_ request: PermissionRequest) async -> PermissionReply { .allowOnce }
}

/// Denies everything that needs approval – for unattended runs.
public struct DenyPrompter: PermissionPrompter {
    public init() {}
    public func requestPermission(_ request: PermissionRequest) async -> PermissionReply {
        .deny(feedback: "No one is available to approve this in an unattended run.")
    }
}
