import AppKit
import ApeironKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct ComposerAttachment: Identifiable, Equatable {
    let id = UUID()
    var filename: String
    var kind: Kind

    enum Kind: Equatable {
        case image(mediaType: String, base64: String)
        case text(String)
    }

    static func load(from url: URL) -> ComposerAttachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .image) {
            let mediaType = type.preferredMIMEType ?? "image/png"
            return ComposerAttachment(filename: url.lastPathComponent, kind: .image(mediaType: mediaType, base64: data.base64EncodedString()))
        }
        guard data.count < 2_000_000, let text = String(data: data, encoding: .utf8) else { return nil }
        return ComposerAttachment(filename: url.lastPathComponent, kind: .text(text))
    }
}

/// Drives one session: owns the agent, turns its events into transcript
/// items, and brokers approvals between the harness and the UI.
@MainActor
@Observable
final class SessionController: Identifiable {
    let id: UUID
    var session: Session
    var items: [TranscriptItem] = []
    var isRunning = false
    var statusText: String?
    var pendingApprovals: [PendingApproval] = []
    var todos: [TodoItem]
    var usage: UsageSnapshot?
    var changedFiles: [ChangedFile] = []
    var errorBanner: String?
    var draft = ""
    var attachments: [ComposerAttachment] = []
    /// Bumped whenever the transcript grows, so the view can follow along.
    var scrollTick = 0
    /// Unattended runs (scheduled tasks) deny approvals instead of waiting.
    var autoDenyApprovals = false
    /// True when the last run was stopped by the user.
    private(set) var wasStopped = false
    /// Called on the main actor when a run ends.
    @ObservationIgnored var onRunFinished: ((SessionController) -> Void)?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var agent: Agent?
    @ObservationIgnored private var projectContext: ProjectContext?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private let prompter = UIPermissionPrompter()
    @ObservationIgnored private var currentText: AssistantTextModel?
    @ObservationIgnored private var currentThinking: ThinkingModel?
    @ObservationIgnored private var toolCards: [String: ToolCardModel] = [:]
    @ObservationIgnored private var requestItemIDs: Set<UUID> = []
    @ObservationIgnored private var pendingDelta = ""
    @ObservationIgnored private var flushScheduled = false

    init(session: Session, app: AppModel) {
        self.id = session.id
        self.session = session
        self.todos = session.todos
        self.app = app
        prompter.controller = self
        rebuildItems()
    }

    var workspaceURL: URL? {
        session.workspacePath.map { URL(fileURLWithPath: $0) }
    }

    var workspaceName: String {
        workspaceURL?.lastPathComponent ?? "No folder"
    }

    var project: Project? {
        session.projectID.flatMap { app?.project(id: $0) }
    }

    /// The last thing the assistant said, for run summaries.
    var lastAssistantText: String? {
        for message in session.messages.reversed() where message.role == .assistant {
            let text = message.blocks.compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    var model: ModelDescriptor {
        app?.model(id: session.modelID) ?? ModelCatalog.builtIn[0]
    }

    var isEmpty: Bool { items.isEmpty && !isRunning }

    var customCommands: [CustomCommand] { projectContext?.commands ?? [] }

    // MARK: Sending

    func submitDraft() {
        let text = draft
        let files = attachments
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return }
        guard !isRunning else { return }
        draft = ""
        attachments = []
        send(text, attachments: files)
    }

    func send(_ rawText: String, attachments: [ComposerAttachment] = []) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if attachments.isEmpty, SlashCommands.isCommand(text) {
            handleSlash(text)
            return
        }
        if session.messages.isEmpty, session.title == "New chat" {
            session.title = Session.title(from: text.isEmpty ? (attachments.first?.filename ?? "Attachment") : text)
        }
        var blocks: [ContentBlock] = []
        var inlined = ""
        for attachment in attachments {
            switch attachment.kind {
            case .image(let mediaType, let base64):
                blocks.append(.image(ImageAttachment(mediaType: mediaType, base64: base64, filename: attachment.filename)))
            case .text(let content):
                inlined += "\n\n<attached_file name=\"\(attachment.filename)\">\n\(content)\n</attached_file>"
            }
        }
        blocks.insert(.text(text + inlined), at: 0)
        let names = attachments.map(\.filename)
        start(userEcho: UserItem(text: text, imageCount: blocks.filter { if case .image = $0 { return true } else { return false } }.count, attachmentNames: names)) { agent in
            agent.send(blocks)
        }
    }

    private func start(userEcho: UserItem?, _ makeStream: @escaping (Agent) -> AsyncStream<AgentEvent>) {
        guard !isRunning else { return }
        errorBanner = nil
        wasStopped = false
        isRunning = true
        statusText = "Thinking"
        if let userEcho {
            append(.user(userEcho))
        }
        app?.noteStarted(session)
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let agent = try await self.ensureAgent()
                for await event in makeStream(agent) {
                    self.apply(event, echoedUser: userEcho != nil)
                }
            } catch {
                self.errorBanner = error.localizedDescription
            }
            await self.finishRun()
        }
    }

    func stop() {
        if isRunning { wasStopped = true }
        for approval in pendingApprovals {
            approval.continuation.resume(returning: .deny(feedback: "The user stopped the agent."))
        }
        pendingApprovals = []
        runTask?.cancel()
    }

    func retryLast() {
        guard !isRunning, let last = session.messages.last(where: { $0.role == .user && $0.kind == .normal && !$0.isToolResultCarrier }) else { return }
        send(stripReminders(last.text))
    }

    // MARK: Model, mode, workspace

    func setModel(_ model: ModelDescriptor) {
        session.modelID = model.id
        guard let agent, let app else { persist(); return }
        do {
            let provider = try app.makeProvider(for: model)
            Task { await agent.setModel(model, provider: provider) }
        } catch {
            errorBanner = error.localizedDescription
        }
        persist()
    }

    func setMode(_ mode: PermissionMode) {
        session.mode = mode
        if let agent { Task { await agent.setMode(mode) } }
        persist()
    }

    func cycleMode() {
        let all = PermissionMode.allCases
        let index = all.firstIndex(of: session.mode) ?? 0
        setMode(all[(index + 1) % all.count])
    }

    func setWorkspace(_ url: URL) {
        guard session.messages.isEmpty else { return }
        session.workspacePath = url.path
        agent = nil
        projectContext = nil
        app?.noteWorkspace(url)
        checkWorkspaceAccess(url)
        Task { self.projectContext = await ProjectContext.load(workspace: url, includeGit: false) }
    }

    /// Moves an untouched chat into a project (or out of one).
    func assign(to project: Project?) {
        guard session.messages.isEmpty, !isRunning else { return }
        session.projectID = project?.id
        if let project {
            session.mode = project.defaultMode
            if let modelID = project.defaultModelID, app?.model(id: modelID) != nil { session.modelID = modelID }
            if let folder = app?.workspace(for: project) {
                setWorkspace(folder)
                return
            }
        }
        agent = nil
        projectContext = nil
    }

    // MARK: Approvals

    func enqueueApproval(_ request: PermissionRequest, continuation: CheckedContinuation<PermissionReply, Never>) {
        if autoDenyApprovals {
            continuation.resume(returning: .deny(feedback: "This is an unattended scheduled run, so actions that need approval are skipped. Carry on without it and mention it in your report."))
            return
        }
        pendingApprovals.append(PendingApproval(request: request, continuation: continuation))
        toolCards[request.toolCall.id]?.status = .awaitingApproval
        NSApp.requestUserAttention(.informationalRequest)
    }

    func resolve(_ approval: PendingApproval, with reply: PermissionReply) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == approval.id }) else { return }
        pendingApprovals.remove(at: index)
        if case .allowAlways(let rule) = reply {
            app?.addAllowRule(rule)
        }
        approval.continuation.resume(returning: reply)
    }

    // MARK: Agent lifecycle

    private func ensureAgent() async throws -> Agent {
        if let agent { return agent }
        guard let app else { throw CancellationError() }
        let workspace = workspaceURL ?? app.defaultWorkspace()
        if session.workspacePath == nil { session.workspacePath = workspace.path }
        checkWorkspaceAccess(workspace)
        let project = await ProjectContext.load(workspace: workspace)
        self.projectContext = project
        let model = self.model
        let provider = try app.makeProvider(for: model)
        let tools = ToolRegistry.standard()
        let linkedProject = self.project
        let taskName = session.scheduledTaskID.flatMap { app.task(id: $0)?.name }
        let systemPrompt = SystemPromptBuilder.build(
            project: project,
            model: model,
            tools: tools,
            userName: app.userFirstName,
            projectBrief: linkedProject.map { ProjectBrief($0) },
            unattendedTask: taskName
        )
        let context = ToolContext(
            workspace: workspace,
            sessionDirectory: app.store.workingDirectory(for: session.id),
            todos: TodoStore(items: session.todos),
            skills: project.skills,
            linkedRoots: linkedProject?.linkedRoots(excluding: workspace) ?? []
        )
        var rules = app.settings.rules
        rules.allow += project.settings.permissions.allow
        rules.deny += project.settings.permissions.deny
        let configuration = Agent.Configuration(
            model: model,
            maxTurns: app.settings.maxTurns,
            effort: model.supportsAdaptiveThinking ? app.settings.effort : nil,
            showThinking: app.settings.showThinking,
            autoCompact: true,
            budget: ContextBudget(contextWindow: model.contextWindow, compactThreshold: app.settings.compactThreshold)
        )
        let agent = Agent(
            provider: provider,
            configuration: configuration,
            systemPrompt: systemPrompt,
            tools: tools,
            policy: PermissionPolicy(mode: session.mode, rules: rules),
            prompter: prompter,
            hooks: HookRunner(hooks: project.settings.hooks, workspace: workspace, sessionID: session.id.uuidString),
            context: context,
            history: session.messages,
            totalUsage: session.usage
        )
        await agent.enableSubagents()
        self.agent = agent
        return agent
    }

    /// Rebuilds the agent on the next message (after settings change).
    /// Touches the folder right away so macOS asks for permission now (not
    /// mid-task), and explains what to do if access is blocked.
    func checkWorkspaceAccess(_ url: URL) {
        if let advice = FileAccess.checkReadable(url) {
            errorBanner = advice
        } else if errorBanner?.contains("macOS blocked access") == true {
            errorBanner = nil
        }
    }

    func invalidateAgent() {
        guard !isRunning else { return }
        agent = nil
    }

    private func finishRun() async {
        flushDelta()
        finalizeStreaming()
        for card in toolCards.values where card.status == .running || card.status == .preparing || card.status == .awaitingApproval {
            card.status = .failed
        }
        isRunning = false
        statusText = nil
        runTask = nil
        if let agent {
            session.messages = await agent.history
            session.usage = await agent.totalUsage
            usage = await agent.usageSnapshot()
        }
        session.todos = todos
        persist()
        onRunFinished?(self)
    }

    private func persist() {
        session.updatedAt = Date()
        guard !session.messages.isEmpty else { return }
        app?.didUpdate(session)
    }

    // MARK: Events → transcript

    private func append(_ item: TranscriptItem) {
        items.append(item)
        requestItemIDs.insert(item.id)
        scrollTick &+= 1
    }

    private func apply(_ event: AgentEvent, echoedUser: Bool) {
        switch event {
        case .userMessage(let message):
            if message.kind == .synthetic {
                append(.notice(NoticeItem(text: stripReminders(message.text), style: .info)))
            }
        case .requestStarted:
            statusText = "Thinking"
            requestItemIDs = []
            currentText = nil
            currentThinking = nil
        case .thinkingDelta(let text):
            if currentThinking == nil {
                let thinking = ThinkingModel(isStreaming: true)
                currentThinking = thinking
                append(.thinking(thinking))
            }
            currentThinking?.text += text
            statusText = "Thinking"
        case .textDelta(let text):
            endThinking()
            if currentText == nil {
                let model = AssistantTextModel(isStreaming: true)
                currentText = model
                append(.assistant(model))
            }
            pendingDelta += text
            scheduleFlush()
            statusText = "Writing"
        case .toolCallStreaming(let id, let name):
            flushDelta()
            endThinking()
            currentText?.isStreaming = false
            currentText = nil
            let card = ToolCardModel(callID: id, name: name, title: name.replacingOccurrences(of: "_", with: " ").capitalized, status: .preparing)
            toolCards[id] = card
            append(.tool(card))
            statusText = name == "write_file" || name == "edit_file" ? "Writing code" : "Preparing \(name.replacingOccurrences(of: "_", with: " "))"
        case .streamReset:
            items.removeAll { requestItemIDs.contains($0.id) }
            requestItemIDs = []
            currentText = nil
            currentThinking = nil
            pendingDelta = ""
        case .assistantMessage(let message):
            flushDelta()
            reconcile(message)
            finalizeStreaming()
        case .toolStarted(let call, let title, let category):
            let card: ToolCardModel
            if let existing = toolCards[call.id] {
                card = existing
            } else {
                card = ToolCardModel(callID: call.id, name: call.name, title: title, status: .running)
                toolCards[call.id] = card
                append(.tool(card))
            }
            card.title = title
            card.category = category
            card.input = call.input
            card.status = .running
            card.startedAt = Date()
            statusText = title
        case .permissionRequested(let request):
            toolCards[request.toolCall.id]?.status = .awaitingApproval
            statusText = "Waiting for your approval"
        case .permissionResolved(let id, let reply):
            if case .deny = reply { toolCards[id]?.status = .denied } else { toolCards[id]?.status = .running }
        case .toolFinished(let call, let result, let metadata, let duration):
            guard let card = toolCards[call.id] else { break }
            card.output = result.content
            card.metadata = metadata
            card.duration = duration
            if card.status != .denied {
                card.status = result.isError ? .failed : .succeeded
            }
            if case .diff(let path, let before, let after)? = metadata {
                recordChange(path: path, before: before, after: after)
            }
        case .toolResultsMessage:
            statusText = "Thinking"
        case .usage(let snapshot):
            usage = snapshot
        case .todos(let items):
            todos = items
        case .compacting:
            statusText = "Compacting the conversation"
        case .compacted:
            append(.notice(NoticeItem(text: "Conversation compacted to free up context. Earlier details are summarised.", style: .compaction)))
        case .retrying(let attempt, let delay, let reason):
            statusText = "Retrying in \(Int(delay.rounded()))s (attempt \(attempt))"
            if attempt == 1 {
                append(.notice(NoticeItem(text: "The provider had a hiccup (\(reason)). Retrying…", style: .warning)))
            }
        case .ruleAdded:
            break
        case .notice(let text):
            append(.notice(NoticeItem(text: text, style: .info)))
        case .finished(let reason):
            switch reason {
            case .completed: break
            case .interrupted: append(.notice(NoticeItem(text: "Stopped.", style: .info)))
            case .maxTurns, .maxTokens, .refused: break
            case .blocked(let why): append(.notice(NoticeItem(text: why, style: .warning)))
            case .failed(let message): append(.notice(NoticeItem(text: message, style: .error)))
            }
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(33))
            self?.flushDelta()
        }
    }

    private func flushDelta() {
        flushScheduled = false
        guard !pendingDelta.isEmpty else { return }
        currentText?.text += pendingDelta
        pendingDelta = ""
        scrollTick &+= 1
    }

    private func endThinking() {
        guard let thinking = currentThinking, thinking.isStreaming else { return }
        thinking.isStreaming = false
        thinking.duration = Date().timeIntervalSince(thinking.startedAt)
    }

    private func finalizeStreaming() {
        endThinking()
        currentText?.isStreaming = false
        currentText = nil
        currentThinking = nil
    }

    /// Makes sure blocks that didn't stream (non-streaming providers) appear.
    private func reconcile(_ message: ChatMessage) {
        let streamedAnything = items.contains { requestItemIDs.contains($0.id) }
        guard !streamedAnything else { return }
        for block in message.blocks {
            switch block {
            case .text(let text) where !text.isEmpty:
                append(.assistant(AssistantTextModel(text: text)))
            case .thinking(let text, _) where !text.isEmpty:
                append(.thinking(ThinkingModel(text: text, duration: 0)))
            default:
                break
            }
        }
    }

    private func recordChange(path: String, before: String, after: String) {
        if let index = changedFiles.firstIndex(where: { $0.path == path }) {
            changedFiles[index].latest = after
        } else {
            changedFiles.append(ChangedFile(path: path, original: before, latest: after))
        }
    }

    /// Rebuilds the transcript from saved history.
    private func rebuildItems() {
        items = []
        toolCards = [:]
        let registry = ToolRegistry.standard()
        for message in session.messages {
            switch message.role {
            case .user:
                for result in message.toolResults {
                    if let card = toolCards[result.toolCallID] {
                        card.output = result.content
                        card.status = result.isError ? .failed : .succeeded
                    }
                }
                if message.kind == .compactionSummary {
                    items.append(.notice(NoticeItem(text: "Conversation compacted to free up context. Earlier details are summarised.", style: .compaction)))
                    continue
                }
                let text = stripReminders(message.text)
                if !text.isEmpty || !message.images.isEmpty {
                    let visible = text.components(separatedBy: "\n\n<attached_file").first ?? text
                    items.append(.user(UserItem(text: visible, imageCount: message.images.count, attachmentNames: [])))
                }
            case .assistant:
                for block in message.blocks {
                    switch block {
                    case .text(let text) where !text.isEmpty:
                        items.append(.assistant(AssistantTextModel(text: text)))
                    case .thinking(let text, _) where !text.isEmpty:
                        items.append(.thinking(ThinkingModel(text: text, duration: 0)))
                    case .toolCall(let call):
                        let tool = registry[call.name]
                        let card = ToolCardModel(
                            callID: call.id,
                            name: call.name,
                            title: tool?.title(for: call.input) ?? call.name,
                            category: tool?.category ?? .meta,
                            input: call.input,
                            status: .succeeded
                        )
                        toolCards[call.id] = card
                        items.append(.tool(card))
                    default:
                        break
                    }
                }
            }
        }
    }

    // MARK: Slash commands

    private func handleSlash(_ text: String) {
        let action = SlashCommands.parse(text, custom: customCommands)
        switch action {
        case .prompt(let prompt):
            send(prompt)
        case .help:
            append(.notice(NoticeItem(text: SlashCommands.helpText, style: .help)))
        case .clear:
            Task { [self] in
                await agent?.clear()
                items = []
                toolCards = [:]
                todos = []
                changedFiles = []
                session.messages = []
                session.todos = []
                app?.didUpdate(session)
            }
        case .compact(let focus):
            guard !session.messages.isEmpty else { return }
            start(userEcho: nil) { agent in agent.compact(focus: focus) }
        case .setModel(let name):
            if let name, let match = app?.findModel(matching: name) {
                setModel(match)
                append(.notice(NoticeItem(text: "Switched to \(match.displayName).", style: .info)))
            } else {
                app?.showModelPicker = true
            }
        case .setMode(let mode):
            if let mode { setMode(mode) } else { cycleMode() }
            append(.notice(NoticeItem(text: "\(session.mode.label): \(session.mode.summary).", style: .info)))
        case .remember(let note):
            guard let workspace = workspaceURL ?? app?.defaultWorkspace() else { return }
            do {
                let url = try SlashCommands.remember(note, workspace: workspace)
                append(.notice(NoticeItem(text: "Saved to \(url.lastPathComponent). It applies from the next session.", style: .info)))
            } catch {
                append(.notice(NoticeItem(text: "Couldn't save the note: \(error.localizedDescription)", style: .error)))
            }
        case .export:
            exportMarkdown()
        case .unknown(let message):
            append(.notice(NoticeItem(text: message, style: .warning)))
        }
    }

    func exportMarkdown() {
        guard let app else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = session.title.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? app.store.markdown(for: session).write(to: url, atomically: true, encoding: .utf8)
    }
}
