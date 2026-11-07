import Foundation

/// Snapshot of token use for the UI.
public struct UsageSnapshot: Sendable, Equatable {
    public var lastRequest: Usage
    public var total: Usage
    public var contextTokens: Int
    public var contextWindow: Int
    public var compactAt: Int
    public var estimatedCost: Double?

    public var contextFraction: Double {
        guard contextWindow > 0 else { return 0 }
        return min(1, Double(contextTokens) / Double(contextWindow))
    }
}

public enum FinishReason: Sendable, Equatable {
    case completed
    case interrupted
    case maxTurns
    case maxTokens
    case refused
    case blocked(String)
    case failed(String)
}

/// Everything the harness reports while it works. Clients render these.
public enum AgentEvent: Sendable {
    case userMessage(ChatMessage)
    case requestStarted(turn: Int)
    case textDelta(String)
    case thinkingDelta(String)
    /// The model has started writing a tool call (its input is streaming).
    case toolCallStreaming(id: String, name: String)
    /// A retry discarded the partial output streamed so far.
    case streamReset
    case assistantMessage(ChatMessage)
    case toolStarted(ToolCall, title: String, category: ToolCategory)
    case permissionRequested(PermissionRequest)
    case permissionResolved(id: String, reply: PermissionReply)
    case toolFinished(ToolCall, ToolResult, metadata: ToolMetadata?, duration: TimeInterval)
    case toolResultsMessage(ChatMessage)
    case usage(UsageSnapshot)
    case todos([TodoItem])
    case compacting
    case compacted(ChatMessage)
    case retrying(attempt: Int, delay: TimeInterval, reason: String)
    case ruleAdded(PermissionRule)
    case notice(String)
    case finished(FinishReason)
}

public typealias AgentEmitter = @Sendable (AgentEvent) -> Void

/// The agent loop: call the model, run the tools it asks for, feed results
/// back, repeat until it's done.
///
/// Invariants the harness maintains:
/// - Every tool call gets exactly one result, in a single user message that
///   immediately follows it, even on errors, denials and interruption.
/// - History is append-only (except compaction, which replaces it wholesale),
///   so provider prompt caches and signed thinking blocks stay valid.
/// - The system prompt and tool list are fixed for the session; mode changes
///   and hook context travel as reminders on the next user message.
public actor Agent {
    public struct Configuration: Sendable {
        public var model: ModelDescriptor
        public var maxTurns: Int
        public var effort: Effort?
        public var showThinking: Bool
        public var autoCompact: Bool
        public var budget: ContextBudget
        public var maxToolOutputCharacters: Int
        public var maxRetries: Int

        public init(
            model: ModelDescriptor,
            maxTurns: Int = 100,
            effort: Effort? = .high,
            showThinking: Bool = true,
            autoCompact: Bool = true,
            budget: ContextBudget? = nil,
            maxToolOutputCharacters: Int = 30_000,
            maxRetries: Int = 4
        ) {
            self.model = model
            self.maxTurns = maxTurns
            self.effort = effort
            self.showThinking = showThinking
            self.autoCompact = autoCompact
            self.budget = budget ?? ContextBudget(contextWindow: model.contextWindow)
            self.maxToolOutputCharacters = maxToolOutputCharacters
            self.maxRetries = maxRetries
        }
    }

    public private(set) var history: [ChatMessage]
    public private(set) var totalUsage: Usage
    public private(set) var policy: PermissionPolicy
    public private(set) var configuration: Configuration
    public let systemPrompt: String
    public let tools: ToolRegistry
    public let context: ToolContext

    private var provider: LLMProvider
    private let prompter: PermissionPrompter
    private let hooks: HookRunner
    private let isSubagent: Bool
    private var lastUsage: Usage?
    private var lastUsageMessageCount = 0
    private var pendingReminders: [String] = []
    private var sessionStarted = false

    public init(
        provider: LLMProvider,
        configuration: Configuration,
        systemPrompt: String,
        tools: ToolRegistry,
        policy: PermissionPolicy,
        prompter: PermissionPrompter,
        hooks: HookRunner,
        context: ToolContext,
        history: [ChatMessage] = [],
        totalUsage: Usage = .zero,
        isSubagent: Bool = false
    ) {
        self.provider = provider
        self.configuration = configuration
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.policy = policy
        self.prompter = prompter
        self.hooks = hooks
        self.context = context
        self.history = history
        self.totalUsage = totalUsage
        self.isSubagent = isSubagent
        self.sessionStarted = !history.isEmpty
    }

    /// Wires up the `task` tool. Call once after creating a top-level agent.
    public func enableSubagents(provider subagentProvider: LLMProvider? = nil, model subagentModel: ModelDescriptor? = nil) {
        guard !isSubagent else { return }
        context.subagentRunner = { [weak self] description, prompt, readOnly in
            guard let self else { throw CancellationError() }
            return try await self.runSubagent(
                description: description,
                prompt: prompt,
                readOnly: readOnly,
                provider: subagentProvider,
                model: subagentModel
            )
        }
    }

    // MARK: Session controls

    public func setMode(_ mode: PermissionMode) {
        guard policy.mode != mode else { return }
        policy.mode = mode
        pendingReminders.removeAll { $0.contains("Mode:") || $0.contains("Plan mode") }
        pendingReminders.append(SystemPromptBuilder.modeReminder(mode))
    }

    public func setRules(_ rules: PermissionRules) {
        policy.rules = rules
    }

    /// Switches model (and provider) for the rest of the session.
    public func setModel(_ model: ModelDescriptor, provider: LLMProvider) {
        configuration.model = model
        configuration.budget = ContextBudget(
            contextWindow: model.contextWindow,
            compactThreshold: configuration.budget.compactThreshold,
            compactCeiling: configuration.budget.compactCeiling
        )
        self.provider = provider
        lastUsage = nil
    }

    public func setEffort(_ effort: Effort?) {
        configuration.effort = effort
    }

    /// Starts over with an empty history.
    public func clear() async {
        history = []
        lastUsage = nil
        lastUsageMessageCount = 0
        await context.files.reset()
        await context.todos.replace([])
    }

    public func usageSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            lastRequest: lastUsage ?? .zero,
            total: totalUsage,
            contextTokens: estimatedContextTokens(),
            contextWindow: configuration.budget.contextWindow,
            compactAt: configuration.budget.compactAt,
            estimatedCost: configuration.model.cost(of: totalUsage)
        )
    }

    func estimatedContextTokens() -> Int {
        ContextEstimator.tokens(
            history: history,
            systemPrompt: systemPrompt,
            toolSpecs: tools.specs,
            lastUsage: lastUsage,
            lastUsageMessageCount: lastUsageMessageCount
        )
    }

    // MARK: Running

    /// Sends a user message and runs the loop until the agent stops.
    /// Cancelling the consumer (or the stream) interrupts the agent safely.
    public nonisolated func send(_ blocks: [ContentBlock]) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(blocks, emit: { continuation.yield($0) })
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public nonisolated func send(_ text: String) -> AsyncStream<AgentEvent> {
        send([.text(text)])
    }

    /// Summarises history to free context (the `/compact` command).
    public nonisolated func compact(focus: String? = nil) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    try await self.performCompaction(focus: focus, emit: { continuation.yield($0) })
                    continuation.yield(.finished(.completed))
                } catch is CancellationError {
                    continuation.yield(.finished(.interrupted))
                } catch {
                    continuation.yield(.finished(.failed(error.localizedDescription)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func run(_ blocks: [ContentBlock], emit: @escaping AgentEmitter) async {
        repairHistory()
        var userBlocks = blocks
        var reminders = pendingReminders
        pendingReminders = []

        if !sessionStarted {
            sessionStarted = true
            if !isSubagent && policy.mode != .ask {
                reminders.append(SystemPromptBuilder.modeReminder(policy.mode))
            }
            let outcome = await hooks.run(.sessionStart)
            reminders += outcome.context.map { "<system-reminder>SessionStart hook:\n\($0)</system-reminder>" }
            outcome.errors.forEach { emit(.notice($0)) }
        }

        let prompt = blocks.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n")
        let submit = await hooks.run(.userPromptSubmit, payload: ["prompt": .string(prompt)])
        submit.errors.forEach { emit(.notice($0)) }
        if submit.blocked {
            let reason = submit.feedback.joined(separator: "\n")
            emit(.notice("A hook blocked this prompt: \(reason)"))
            emit(.finished(.blocked(reason)))
            return
        }
        reminders += submit.context.map { "<system-reminder>UserPromptSubmit hook:\n\($0)</system-reminder>" }
        if !reminders.isEmpty {
            userBlocks.append(.text(reminders.joined(separator: "\n")))
        }

        let message = ChatMessage(role: .user, blocks: userBlocks)
        history.append(message)
        emit(.userMessage(message))
        await loop(emit: emit)
    }

    private func loop(emit: @escaping AgentEmitter) async {
        var turn = 0
        var stopHookContinuations = 0
        do {
            while true {
                try Task.checkCancellation()
                if turn >= configuration.maxTurns {
                    emit(.notice("Stopped after \(configuration.maxTurns) steps. Send a message to let me continue."))
                    emit(.finished(.maxTurns))
                    return
                }
                turn += 1

                if configuration.autoCompact, history.count > 2,
                   estimatedContextTokens() > configuration.budget.compactAt {
                    try await performCompaction(focus: nil, emit: emit)
                }

                emit(.requestStarted(turn: turn))
                let response = try await requestWithRetry(emit: emit)
                let assistant = ChatMessage(
                    role: .assistant,
                    blocks: response.blocks,
                    modelID: configuration.model.id,
                    usage: response.usage
                )
                history.append(assistant)
                totalUsage += response.usage
                lastUsage = response.usage
                lastUsageMessageCount = history.count
                emit(.assistantMessage(assistant))
                emit(.usage(usageSnapshot()))

                let calls = assistant.toolCalls
                if response.stopReason == .refusal {
                    emit(.notice("The model declined to continue with this request."))
                    if calls.isEmpty {
                        emit(.finished(.refused))
                        return
                    }
                }

                if calls.isEmpty {
                    if response.stopReason == .pauseTurn { continue }
                    if response.stopReason == .maxTokens {
                        emit(.notice("The response hit the output limit. Ask me to continue."))
                        emit(.finished(.maxTokens))
                        return
                    }
                    let stop = await hooks.run(.stop, payload: ["stop_hook_active": .bool(stopHookContinuations > 0)])
                    stop.errors.forEach { emit(.notice($0)) }
                    if stop.blocked, stopHookContinuations < 3 {
                        stopHookContinuations += 1
                        let nudge = ChatMessage(
                            role: .user,
                            blocks: [.text("<system-reminder>A Stop hook asked you to keep going:\n\(stop.feedback.joined(separator: "\n"))</system-reminder>")],
                            kind: .synthetic
                        )
                        history.append(nudge)
                        emit(.userMessage(nudge))
                        continue
                    }
                    emit(.finished(.completed))
                    return
                }

                let results = await executeToolCalls(calls, emit: emit)
                let carrier = ChatMessage(role: .user, blocks: results.map { .toolResult($0) })
                history.append(carrier)
                emit(.toolResultsMessage(carrier))
                emit(.usage(usageSnapshot()))
                try Task.checkCancellation()
            }
        } catch is CancellationError {
            repairHistory()
            emit(.finished(.interrupted))
        } catch {
            repairHistory()
            emit(.finished(.failed(error.localizedDescription)))
        }
    }

    private func requestWithRetry(emit: @escaping AgentEmitter) async throws -> ModelResponse {
        var attempt = 0
        while true {
            var partialText = ""
            var streamedAnything = false
            do {
                let request = ModelRequest(
                    model: configuration.model,
                    system: systemPrompt,
                    messages: history,
                    tools: configuration.model.supportsTools ? tools.specs : [],
                    effort: configuration.effort,
                    showThinking: configuration.showThinking
                )
                var final: ModelResponse?
                for try await event in provider.stream(request) {
                    switch event {
                    case .textDelta(let text):
                        partialText += text
                        streamedAnything = true
                        emit(.textDelta(text))
                    case .thinkingDelta(let text):
                        streamedAnything = true
                        emit(.thinkingDelta(text))
                    case .toolCallStarted(let id, let name):
                        streamedAnything = true
                        emit(.toolCallStreaming(id: id, name: name))
                    case .toolInputDelta, .usage:
                        break
                    case .completed(let response):
                        final = response
                    }
                }
                try Task.checkCancellation()
                guard let final else { throw ProviderError.malformedResponse("The stream ended early.") }
                return final
            } catch is CancellationError {
                if !partialText.isEmpty {
                    history.append(ChatMessage(role: .assistant, blocks: [.text(partialText + "\n\n[interrupted]")], modelID: configuration.model.id))
                }
                throw CancellationError()
            } catch let error as ProviderError where error.isRetryable && attempt < configuration.maxRetries {
                attempt += 1
                let backoff = min(30, pow(2, Double(attempt)) + Double.random(in: 0...1))
                let delay = error.retryAfter.map { min($0, 60) } ?? backoff
                if streamedAnything { emit(.streamReset) }
                emit(.retrying(attempt: attempt, delay: delay, reason: error.localizedDescription))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    // MARK: Tools

    private func executeToolCalls(_ calls: [ToolCall], emit: @escaping AgentEmitter) async -> [ToolResult] {
        // Consecutive read-only calls run concurrently; anything that changes
        // state runs alone, in order.
        var batches: [[ToolCall]] = []
        for call in calls {
            let parallel = tools[call.name]?.category.isReadOnly ?? true
            if parallel, let last = batches.last, let first = last.first, tools[first.name]?.category.isReadOnly ?? true {
                batches[batches.count - 1].append(call)
            } else {
                batches.append([call])
            }
        }

        var results: [String: ToolResult] = [:]
        for batch in batches {
            if Task.isCancelled {
                for call in batch {
                    results[call.id] = ToolResult(toolCallID: call.id, content: "Interrupted by the user before this ran.", isError: true)
                }
                continue
            }
            if batch.count == 1, let call = batch.first {
                results[call.id] = await executeOne(call, emit: emit)
            } else {
                await withTaskGroup(of: ToolResult.self) { group in
                    for call in batch {
                        group.addTask { await self.executeOne(call, emit: emit) }
                    }
                    for await result in group {
                        results[result.toolCallID] = result
                    }
                }
            }
        }
        return calls.map {
            results[$0.id] ?? ToolResult(toolCallID: $0.id, content: "Interrupted by the user before this ran.", isError: true)
        }
    }

    private func executeOne(_ call: ToolCall, emit: @escaping AgentEmitter) async -> ToolResult {
        let start = Date()
        guard let tool = tools[call.name] else {
            let names = tools.tools.map(\.name).joined(separator: ", ")
            let result = ToolResult(toolCallID: call.id, content: "Unknown tool \(call.name). Available tools: \(names).", isError: true)
            emit(.toolStarted(call, title: call.name, category: .meta))
            emit(.toolFinished(call, result, metadata: nil, duration: 0))
            return result
        }
        let title = tool.title(for: call.input)
        emit(.toolStarted(call, title: title, category: tool.category))

        func finish(_ output: ToolOutput) -> ToolResult {
            var content = output.content
            if content.count > configuration.maxToolOutputCharacters {
                content = spill(content, callID: call.id)
            }
            let result = ToolResult(toolCallID: call.id, content: content, isError: output.isError)
            emit(.toolFinished(call, result, metadata: output.metadata, duration: Date().timeIntervalSince(start)))
            return result
        }

        if let parseError = call.inputParseError {
            return finish(.error("\(parseError). Send the call again with complete, valid arguments."))
        }
        if let problem = tool.validate(call.input) {
            return finish(.error(problem))
        }
        if Task.isCancelled {
            return finish(.error("Interrupted by the user before this ran."))
        }

        let pre = await hooks.run(.preToolUse, toolName: call.name, payload: ["tool_input": call.input])
        pre.errors.forEach { emit(.notice($0)) }
        if pre.blocked {
            return finish(.error("A PreToolUse hook blocked this call: \(pre.feedback.joined(separator: "\n"))"))
        }

        switch policy.evaluate(tool: tool, input: call.input, context: context) {
        case .allow:
            break
        case .deny(let reason):
            return finish(.error("Not permitted: \(reason)"))
        case .ask(let reason):
            let subject = tool.permissionSubject(for: call.input)
            let request = PermissionRequest(
                toolCall: call,
                toolName: tool.name,
                category: tool.category,
                title: title,
                subject: subject,
                reason: reason,
                preview: await tool.preview(for: call.input, context: context),
                suggestedRule: PermissionRule.suggested(tool: tool.name, category: tool.category, subject: subject)
            )
            emit(.permissionRequested(request))
            let reply = await prompter.requestPermission(request)
            emit(.permissionResolved(id: call.id, reply: reply))
            switch reply {
            case .allowOnce:
                break
            case .allowAlways(let rule):
                if !policy.rules.allow.contains(rule) {
                    policy.rules.allow.append(rule)
                    emit(.ruleAdded(rule))
                }
            case .deny(let feedback):
                var message = "The user declined this action."
                if let feedback, !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    message += " Their feedback: \(feedback)"
                } else {
                    message += " Don't retry it unchanged; adjust your approach or ask what they'd prefer."
                }
                return finish(.error(message))
            }
            if Task.isCancelled {
                return finish(.error("Interrupted by the user before this ran."))
            }
        }

        var output: ToolOutput
        do {
            output = try await tool.run(call.input, context: context)
        } catch is CancellationError {
            output = .error("Interrupted by the user while running.")
        } catch {
            output = .error("\(tool.name) failed: \(error.localizedDescription)")
        }

        let post = await hooks.run(.postToolUse, toolName: call.name, payload: [
            "tool_input": call.input,
            "tool_response": .string(String(output.content.prefix(20_000))),
            "is_error": .bool(output.isError),
        ])
        post.errors.forEach { emit(.notice($0)) }
        if post.blocked {
            output.content += "\n\n[PostToolUse hook feedback]\n" + post.feedback.joined(separator: "\n")
        }
        if case .todos(let items) = output.metadata {
            emit(.todos(items))
        }
        return finish(output)
    }

    /// Saves oversized output to the session folder and returns a trimmed
    /// version that tells the model where the rest is.
    private func spill(_ content: String, callID: String) -> String {
        let directory = context.sessionDirectory.appendingPathComponent("tool-output")
        let file = directory.appendingPathComponent("\(callID.replacingOccurrences(of: "/", with: "_")).txt")
        var note = "Output truncated: \(content.count) characters in total."
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
            note += " The full output is saved at \(file.path); use read_file with offset and limit, or grep, to look at specific parts."
        } catch {
            note += " (Could not save the full output: \(error.localizedDescription))"
        }
        return TextUtils.truncateMiddle(content, maxCharacters: configuration.maxToolOutputCharacters, note: note)
    }

    // MARK: History integrity

    /// Ensures every tool call has a result right after it.
    func repairHistory() {
        var index = 0
        while index < history.count {
            let message = history[index]
            let ids = message.role == .assistant ? message.toolCalls.map(\.id) : []
            if !ids.isEmpty {
                let next = index + 1
                if next < history.count, history[next].role == .user {
                    let present = Set(history[next].toolResults.map(\.toolCallID))
                    let missing = ids.filter { !present.contains($0) }
                    if !missing.isEmpty {
                        let filler = missing.map { ContentBlock.toolResult(ToolResult(toolCallID: $0, content: "Interrupted before this ran.", isError: true)) }
                        history[next].blocks = filler + history[next].blocks
                    }
                } else {
                    let filler = ids.map { ContentBlock.toolResult(ToolResult(toolCallID: $0, content: "Interrupted before this ran.", isError: true)) }
                    history.insert(ChatMessage(role: .user, blocks: filler, kind: .synthetic), at: next)
                }
            }
            index += 1
        }
    }

    // MARK: Compaction

    private func performCompaction(focus: String?, emit: @escaping AgentEmitter) async throws {
        guard !history.isEmpty else { return }
        repairHistory()
        emit(.compacting)
        // A just-sent prompt stays verbatim after the summary so the model
        // answers it directly rather than a paraphrase of it.
        var kept: [ChatMessage] = []
        var toSummarise = history
        if let last = history.last, last.role == .user, !last.isToolResultCarrier, history.count > 1 {
            kept = [last]
            toSummarise.removeLast()
        }
        let todos = await context.todos.items
        let (summary, usage) = try await Compactor.compact(
            history: toSummarise,
            todos: todos,
            provider: provider,
            model: configuration.model,
            focus: focus
        )
        history = [summary] + kept
        totalUsage += usage
        lastUsage = nil
        lastUsageMessageCount = 0
        await context.files.reset()
        emit(.compacted(summary))
        emit(.usage(usageSnapshot()))
    }

    // MARK: Subagents

    private func runSubagent(
        description: String,
        prompt: String,
        readOnly: Bool,
        provider subagentProvider: LLMProvider?,
        model subagentModel: ModelDescriptor?
    ) async throws -> (String, Int) {
        let childDirectory = context.sessionDirectory.appendingPathComponent("subagents/\(UUID().uuidString.prefix(8))")
        let childContext = ToolContext(
            workspace: context.workspace,
            sessionDirectory: childDirectory,
            files: context.files,
            todos: TodoStore(),
            skills: context.skills
        )
        let childTools = readOnly ? ToolRegistry.readOnly() : ToolRegistry.standard(includeSubagents: false)
        let model = subagentModel ?? configuration.model
        let childPrompt = systemPrompt + """


        # You are a subagent
        A parent agent delegated one task to you: “\(description)”. You can't talk to the user and the parent \
        sees only your final message, so finish with a complete, self-contained report: what you found or did, \
        with file paths and line numbers. Be thorough but don't pad.\(readOnly ? " You have read-only tools." : "")
        """
        let child = Agent(
            provider: subagentProvider ?? provider,
            configuration: Configuration(
                model: model,
                maxTurns: 40,
                effort: .medium,
                showThinking: false,
                autoCompact: true,
                maxToolOutputCharacters: configuration.maxToolOutputCharacters
            ),
            systemPrompt: childPrompt,
            tools: childTools,
            policy: policy,
            prompter: prompter,
            hooks: hooks,
            context: childContext,
            isSubagent: true
        )
        var report = ""
        var steps = 0
        var failure: String?
        for await event in child.send(prompt) {
            switch event {
            case .assistantMessage(let message):
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { report = text }
            case .toolFinished:
                steps += 1
            case .finished(let reason):
                if case .failed(let message) = reason { failure = message }
            default:
                break
            }
        }
        totalUsage += await child.totalUsage
        try Task.checkCancellation()
        if let failure, report.isEmpty { throw ToolInputError("The subagent failed: \(failure)") }
        return (report, steps)
    }
}
