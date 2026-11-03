import Foundation

public enum HookEvent: String, Codable, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case stop = "Stop"
}

/// A user script run on a harness event. It receives a JSON payload on stdin.
///
/// Exit codes follow the Claude Code convention:
/// - 0: success; stdout is added as context for SessionStart/UserPromptSubmit.
/// - 2: block; stderr is fed back to the model (PreToolUse blocks the call,
///   UserPromptSubmit blocks the prompt, Stop makes the agent keep working).
/// - anything else: a non-blocking error shown to the user.
public struct HookDefinition: Codable, Sendable, Hashable {
    public var event: HookEvent
    /// Regular expression matched against the tool name (tool events only).
    public var matcher: String?
    public var command: String
    public var timeout: TimeInterval?

    public init(event: HookEvent, matcher: String? = nil, command: String, timeout: TimeInterval? = nil) {
        self.event = event
        self.matcher = matcher
        self.command = command
        self.timeout = timeout
    }

    func applies(toTool name: String?) -> Bool {
        guard let matcher, !matcher.isEmpty, matcher != "*" else { return true }
        guard let name else { return false }
        return name.range(of: "^(?:\(matcher))$", options: .regularExpression) != nil
    }
}

public struct HookOutcome: Sendable {
    public var blocked: Bool = false
    public var feedback: [String] = []
    public var context: [String] = []
    public var errors: [String] = []
}

public struct HookRunner: Sendable {
    public var hooks: [HookDefinition]
    public var workspace: URL
    public var sessionID: String

    public init(hooks: [HookDefinition], workspace: URL, sessionID: String) {
        self.hooks = hooks
        self.workspace = workspace
        self.sessionID = sessionID
    }

    public var isEmpty: Bool { hooks.isEmpty }

    public func run(_ event: HookEvent, toolName: String? = nil, payload: [String: JSONValue] = [:]) async -> HookOutcome {
        var outcome = HookOutcome()
        let matching = hooks.filter { $0.event == event && $0.applies(toTool: toolName) }
        guard !matching.isEmpty else { return outcome }
        var body = payload
        body["hook_event_name"] = .string(event.rawValue)
        body["session_id"] = .string(sessionID)
        body["cwd"] = .string(workspace.path)
        if let toolName { body["tool_name"] = .string(toolName) }
        let stdin = JSONValue.object(body).data()

        for hook in matching {
            do {
                let result = try await Shell.run(
                    hook.command,
                    in: workspace,
                    timeout: hook.timeout ?? 60,
                    stdin: stdin,
                    environment: ["APEIRON_PROJECT_DIR": workspace.path, "APEIRON_HOOK_EVENT": event.rawValue]
                )
                let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                switch result.exitCode {
                case 0:
                    if !stdout.isEmpty { outcome.context.append(stdout) }
                case 2:
                    outcome.blocked = true
                    outcome.feedback.append(stderr.isEmpty ? "Blocked by a \(event.rawValue) hook." : stderr)
                default:
                    outcome.errors.append("Hook `\(hook.command)` exited \(result.exitCode): \(stderr.isEmpty ? stdout : stderr)")
                }
            } catch {
                outcome.errors.append("Hook `\(hook.command)` failed: \(error.localizedDescription)")
            }
        }
        return outcome
    }
}
