import ApeironKit
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// apeiron: the same harness as the app, in a terminal.
//
//   apeiron                      interactive session in the current folder
//   apeiron -p "fix the tests"   one prompt, then exit (headless)
//   apeiron --demo               offline demo provider, no key needed
//   apeiron --model sonnet --mode auto-edit

// MARK: Terminal styling

enum Style {
    static let isTTY = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    static func wrap(_ code: String, _ text: String) -> String { isTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
    static func dim(_ text: String) -> String { wrap("2", text) }
    static func bold(_ text: String) -> String { wrap("1", text) }
    static func accent(_ text: String) -> String { wrap("38;5;173", text) }
    static func green(_ text: String) -> String { wrap("32", text) }
    static func red(_ text: String) -> String { wrap("31", text) }
    static func yellow(_ text: String) -> String { wrap("33", text) }
}

func write(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

func writeError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

// MARK: Arguments

struct Options {
    var prompt: String?
    var modelQuery: String?
    var mode: PermissionMode = .ask
    var demo = false
    var workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var effort: Effort = .high
    var showThinking = false
    var maxTurns = 100
}

func usage() -> String {
    """
    apeiron – a coding agent in your terminal

    USAGE: apeiron [options] [prompt]

    OPTIONS:
      -p, --print <prompt>   Run one prompt headlessly and exit
      -m, --model <name>     Model id or name (default: Claude Opus 5.5)
          --mode <mode>      ask | auto-edit | plan | full-access (default: ask)
          --effort <level>   low | medium | high | xhigh | max (default: high)
          --thinking         Show the model's thinking summaries
      -C, --cwd <path>       Workspace folder (default: current directory)
          --demo             Use the offline demo provider (no API key)
          --max-turns <n>    Cap tool-use turns per message (default: 100)
          --list-models      Print the model catalog and exit
      -h, --help             Show this help

    Keys are read from ANTHROPIC_API_KEY, OPENAI_API_KEY, OPENROUTER_API_KEY,
    GEMINI_API_KEY, MISTRAL_API_KEY, DEEPSEEK_API_KEY and MINIMAX_API_KEY.
    """
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    var positional: [String] = []
    func value(_ flag: String) -> String {
        guard !args.isEmpty else {
            writeError("apeiron: \(flag) needs a value")
            exit(2)
        }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "-h", "--help":
            print(usage())
            exit(0)
        case "-p", "--print": options.prompt = value(arg)
        case "-m", "--model": options.modelQuery = value(arg)
        case "--mode":
            let name = value(arg)
            guard let mode = SlashCommands.mode(named: name) else {
                writeError("apeiron: unknown mode '\(name)'")
                exit(2)
            }
            options.mode = mode
        case "--effort":
            let name = value(arg)
            guard let effort = Effort(rawValue: name) else {
                writeError("apeiron: unknown effort '\(name)'")
                exit(2)
            }
            options.effort = effort
        case "--thinking": options.showThinking = true
        case "-C", "--cwd":
            let path = (value(arg) as NSString).expandingTildeInPath
            options.workspace = URL(fileURLWithPath: path)
        case "--demo": options.demo = true
        case "--max-turns": options.maxTurns = Int(value(arg)) ?? options.maxTurns
        case "--list-models":
            for model in ModelCatalog.builtIn {
                print("\(model.id.padding(toLength: 44, withPad: " ", startingAt: 0)) \(model.displayName)")
            }
            exit(0)
        default:
            if arg.hasPrefix("-") {
                writeError("apeiron: unknown option \(arg)\n\n\(usage())")
                exit(2)
            }
            positional.append(arg)
        }
    }
    if options.prompt == nil, !positional.isEmpty {
        options.prompt = positional.joined(separator: " ")
    }
    return options
}

func resolveModel(_ options: Options) -> ModelDescriptor {
    if options.demo {
        return ModelCatalog.builtIn.first { $0.provider == .demo }!
    }
    guard let query = options.modelQuery?.lowercased() else {
        return ModelCatalog.model(id: ModelCatalog.defaultModelID)!
    }
    let all = ModelCatalog.builtIn
    if let exact = all.first(where: { $0.id.lowercased() == query || $0.apiModel.lowercased() == query }) {
        return exact
    }
    if let fuzzy = all.first(where: { $0.displayName.lowercased().contains(query) || $0.apiModel.lowercased().contains(query) }) {
        return fuzzy
    }
    // "provider/model" for anything not in the catalog.
    let parts = query.split(separator: "/", maxSplits: 1).map(String.init)
    if parts.count == 2, let provider = ProviderKind(rawValue: parts[0]) {
        return ModelDescriptor(provider: provider, apiModel: parts[1], displayName: parts[1], isCustom: true)
    }
    writeError("apeiron: unknown model '\(query)'. Try --list-models.")
    exit(2)
}

// MARK: Approvals

/// Asks on the terminal. Serialised so parallel tool calls don't interleave prompts.
actor TerminalPrompter: PermissionPrompter {
    let interactive: Bool

    init(interactive: Bool) {
        self.interactive = interactive
    }

    func requestPermission(_ request: PermissionRequest) async -> PermissionReply {
        guard interactive else {
            return .deny(feedback: "Running headlessly; this needs approval. Use --mode full-access or an allow rule.")
        }
        write("\n" + Style.yellow("●") + " " + Style.bold(request.title))
        if let subject = request.subject { write(" " + Style.dim(subject)) }
        write("\n")
        if let reason = request.reason { write(Style.dim("  \(reason)") + "\n") }
        switch request.preview {
        case .command(let command):
            write(Style.dim("  $ ") + command + "\n")
        case .diff(_, let before, let after):
            for line in LineDiff.hunks(before: before, after: after).flatMap(\.lines).prefix(40) {
                switch line.kind {
                case .added: write(Style.green("  + \(line.text)") + "\n")
                case .removed: write(Style.red("  - \(line.text)") + "\n")
                case .context: write(Style.dim("    \(line.text)") + "\n")
                }
            }
        case .text(let text):
            write(Style.dim(TextUtils.truncateMiddle(text, maxCharacters: 1200)) + "\n")
        case nil:
            break
        }
        write("  Allow? " + Style.dim("[y]es  [a]lways (\(request.suggestedRule))  [n]o, or type feedback: "))
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces) else {
            return .deny(feedback: nil)
        }
        switch answer.lowercased() {
        case "y", "yes", "": return .allowOnce
        case "a", "always": return .allowAlways(request.suggestedRule)
        case "n", "no": return .deny(feedback: nil)
        default: return .deny(feedback: answer)
        }
    }
}

// MARK: Rendering

final class Renderer: @unchecked Sendable {
    private var lastKind: Kind = .none
    private var startedText = false
    let showThinking: Bool

    enum Kind { case none, text, thinking, tool }

    init(showThinking: Bool) {
        self.showThinking = showThinking
    }

    private func transition(to kind: Kind) {
        if lastKind != kind && lastKind != .none { write("\n") }
        if kind == .text && lastKind != .text { write("\n") }
        lastKind = kind
    }

    func render(_ event: AgentEvent) {
        switch event {
        case .textDelta(let text):
            transition(to: .text)
            write(text)
        case .thinkingDelta(let text):
            guard showThinking else { return }
            transition(to: .thinking)
            write(Style.dim(text))
        case .toolStarted(_, let title, _):
            transition(to: .tool)
            write(Style.accent("⏺ ") + title + "\n")
        case .toolFinished(_, let result, let metadata, let duration):
            lastKind = .tool
            let mark = result.isError ? Style.red("  ⎿ ") : Style.dim("  ⎿ ")
            write(mark + Style.dim(summary(of: result, metadata: metadata) + " · " + String(format: "%.1fs", duration)) + "\n")
        case .retrying(let attempt, let delay, let reason):
            transition(to: .tool)
            write(Style.yellow("  ↻ ") + Style.dim("\(reason). Retrying in \(Int(delay.rounded()))s (attempt \(attempt))") + "\n")
        case .compacting:
            transition(to: .tool)
            write(Style.dim("  Compacting the conversation…") + "\n")
        case .compacted:
            write(Style.dim("  Compacted. Earlier turns are now a summary.") + "\n")
        case .notice(let text):
            transition(to: .tool)
            write(Style.dim("  \(text)") + "\n")
        case .todos(let items):
            transition(to: .tool)
            for item in items {
                let box: String
                switch item.status {
                case .completed: box = Style.green("  ☒ ") + Style.dim(item.content)
                case .inProgress: box = Style.accent("  ◐ ") + Style.bold(item.content)
                case .pending: box = "  ☐ " + item.content
                }
                write(box + "\n")
            }
        case .finished(let reason):
            if lastKind != .none { write("\n") }
            lastKind = .none
            switch reason {
            case .completed: break
            case .interrupted: write(Style.yellow("Interrupted.") + "\n")
            case .maxTurns: write(Style.yellow("Stopped after reaching the turn limit.") + "\n")
            case .maxTokens: write(Style.yellow("The reply hit the output limit.") + "\n")
            case .refused: write(Style.yellow("The model declined this request.") + "\n")
            case .blocked(let message): write(Style.yellow("Blocked: \(message)") + "\n")
            case .failed(let message): write(Style.red("Error: \(message)") + "\n")
            }
        default:
            break
        }
    }

    private func summary(of result: ToolResult, metadata: ToolMetadata?) -> String {
        switch metadata {
        case .diff(let path, let before, let after):
            let (added, removed) = LineDiff.stats(before: before, after: after)
            return "\(URL(fileURLWithPath: path).lastPathComponent) +\(added) −\(removed)"
        case .command(_, let exitCode, let timedOut):
            return timedOut ? "timed out" : "exit \(exitCode)"
        case .fileRead(_, let lineCount):
            return "\(lineCount) lines"
        case .subagent(let steps):
            return "done in \(steps) steps"
        case .todos(let items):
            return "\(items.filter { $0.status == .completed }.count)/\(items.count) done"
        case nil:
            let first = result.content.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "done"
            return TextUtils.truncateMiddle(first, maxCharacters: 100)
        }
    }
}

// MARK: Interrupts

/// Ctrl-C stops the current run; a second Ctrl-C at the prompt exits.
final class InterruptHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Task<Void, Never>?
    private var source: DispatchSourceSignal?

    func install() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let task = self.current
            self.lock.unlock()
            if let task {
                task.cancel()
            } else {
                write("\n")
                exit(130)
            }
        }
        source.resume()
        self.source = source
    }

    func run(_ task: Task<Void, Never>) async {
        setCurrent(task)
        await task.value
        setCurrent(nil)
    }

    private func setCurrent(_ task: Task<Void, Never>?) {
        lock.lock()
        current = task
        lock.unlock()
    }
}

// MARK: Main

// print() and FileHandle writes share one unbuffered stream, so output stays ordered.
setvbuf(stdout, nil, _IONBF, 0)

let options = parseOptions()
let model = resolveModel(options)
let env = ProcessInfo.processInfo.environment
let apiKey = env[model.provider.environmentKey] ?? ""
if model.provider.requiresAPIKey && apiKey.isEmpty {
    writeError("apeiron: set \(model.provider.environmentKey) to use \(model.displayName), or run with --demo.")
    exit(1)
}

let workspace = options.workspace.standardizedFileURL
let project = await ProjectContext.load(workspace: workspace)
let tools = ToolRegistry.standard()
let store = SessionStore()
var session = Session(workspacePath: workspace.path, modelID: model.id, mode: options.mode)
let provider = ProviderFactory.make(for: model, apiKey: apiKey, baseURL: env["APEIRON_BASE_URL"].flatMap(URL.init(string:)))
var rules = project.settings.permissions
let interactive = options.prompt == nil && isatty(STDIN_FILENO) != 0

let agent = Agent(
    provider: provider,
    configuration: Agent.Configuration(
        model: model,
        maxTurns: options.maxTurns,
        effort: model.supportsAdaptiveThinking ? options.effort : nil,
        showThinking: options.showThinking,
        autoCompact: true,
        budget: ContextBudget(contextWindow: model.contextWindow)
    ),
    systemPrompt: SystemPromptBuilder.build(project: project, model: model, tools: tools, userName: nil),
    tools: tools,
    policy: PermissionPolicy(mode: options.mode, rules: rules),
    prompter: TerminalPrompter(interactive: options.prompt == nil),
    hooks: HookRunner(hooks: project.settings.hooks, workspace: workspace, sessionID: session.id.uuidString),
    context: ToolContext(
        workspace: workspace,
        sessionDirectory: store.workingDirectory(for: session.id),
        todos: TodoStore(items: []),
        skills: project.skills
    ),
    history: [],
    totalUsage: .zero
)
await agent.enableSubagents()

let renderer = Renderer(showThinking: options.showThinking)
let interrupts = InterruptHandler()
interrupts.install()

func run(_ stream: AsyncStream<AgentEvent>) async -> FinishReason? {
    let box = FinishBox()
    let task = Task {
        for await event in stream {
            renderer.render(event)
            if case .finished(let reason) = event { box.set(reason) }
        }
    }
    await interrupts.run(task)
    return box.reason
}

final class FinishBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FinishReason?
    func set(_ reason: FinishReason) { lock.lock(); value = reason; lock.unlock() }
    var reason: FinishReason? { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
func persist() async {
    session.messages = await agent.history
    session.usage = await agent.totalUsage
    session.updatedAt = Date()
    if session.title == "New chat", let first = session.messages.first(where: { $0.role == .user && $0.kind == .normal }) {
        session.title = Session.title(from: stripReminders(first.text))
    }
    try? store.save(session)
}

// Headless: one prompt, print the answer, exit with a useful status.
if let prompt = options.prompt {
    let reason = await run(agent.send(prompt))
    await persist()
    switch reason {
    case .completed?: exit(0)
    case .interrupted?: exit(130)
    default: exit(1)
    }
}

// Interactive REPL.
let banner = """
\(Style.accent("✻")) \(Style.bold("Apeiron")) \(Style.dim("· \(model.displayName) · \(options.mode.label) · \(workspace.path)"))
\(Style.dim("  /help for commands · Ctrl-C stops a run · Ctrl-D quits"))
"""
print(banner)
if !project.memory.isEmpty {
    print(Style.dim("  Loaded \(project.memory.map { $0.url.lastPathComponent }.joined(separator: ", "))"))
}

var mode = options.mode
while true {
    write("\n" + Style.accent("› "))
    guard let line = readLine() else {
        write("\n")
        break
    }
    let input = line.trimmingCharacters(in: .whitespaces)
    if input.isEmpty { continue }

    if SlashCommands.isCommand(input) {
        switch SlashCommands.parse(input, custom: project.commands) {
        case .prompt(let prompt):
            _ = await run(agent.send(prompt))
            await persist()
        case .help:
            print(SlashCommands.helpText)
        case .clear:
            await agent.clear()
            session = Session(workspacePath: workspace.path, modelID: model.id, mode: mode)
            print(Style.dim("Cleared. Starting fresh."))
        case .compact(let focus):
            _ = await run(agent.compact(focus: focus))
            await persist()
        case .setModel:
            print(Style.dim("Restart with --model to switch models in the terminal."))
        case .setMode(let newMode):
            let all = PermissionMode.allCases
            mode = newMode ?? all[((all.firstIndex(of: mode) ?? 0) + 1) % all.count]
            await agent.setMode(mode)
            print(Style.dim("\(mode.label): \(mode.summary)."))
        case .remember(let note):
            do {
                let url = try SlashCommands.remember(note, workspace: workspace)
                print(Style.dim("Saved to \(url.path)."))
            } catch {
                print(Style.red("Couldn't save: \(error.localizedDescription)"))
            }
        case .export:
            await persist()
            let url = workspace.appendingPathComponent("apeiron-\(session.id.uuidString.prefix(8)).md")
            try? store.markdown(for: session).write(to: url, atomically: true, encoding: .utf8)
            print(Style.dim("Exported to \(url.path)."))
        case .unknown(let message):
            print(Style.yellow(message))
        }
        continue
    }

    _ = await run(agent.send(input))
    await persist()
    let snapshot = await agent.usageSnapshot()
    var footer = "\(snapshot.contextTokens.formatted()) tokens in context (\(Int((snapshot.contextFraction * 100).rounded()))%)"
    if let cost = snapshot.estimatedCost { footer += String(format: " · $%.3f this session", cost) }
    print(Style.dim(footer))
}
