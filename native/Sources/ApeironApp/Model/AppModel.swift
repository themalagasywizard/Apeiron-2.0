import AppKit
import ApeironKit
import Foundation
import Observation
import UserNotifications

/// What the main area shows.
enum AppRoute: Equatable {
    case chat
    case tasks
}

@MainActor
@Observable
final class AppModel {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if settings.effort != oldValue.effort || settings.showThinking != oldValue.showThinking
                || settings.rules != oldValue.rules || settings.maxTurns != oldValue.maxTurns
                || settings.compactThreshold != oldValue.compactThreshold {
                controllers.values.forEach { $0.invalidateAgent() }
            }
        }
    }
    var summaries: [SessionSummary] = []
    var selection: UUID?
    var searchText = ""
    var showCommandPalette = false
    var showModelPicker = false
    var showInspector = true
    var showOpenRouterBrowser = false
    var openRouterEntries: [OpenRouterCatalog.Entry] = []
    var openRouterLoading = false
    var openRouterError: String?
    var keyPresence: [ProviderKind: Bool] = [:]

    var route: AppRoute = .chat
    var projects: [Project] = []
    var expandedProjects: Set<UUID> = []
    /// The project being created or edited in the project sheet.
    var projectDraft: ProjectDraft?
    var tasks: [ScheduledTask] = []
    /// The task being created or edited in the task sheet.
    var taskDraft: ScheduledTask?
    var runningTaskIDs: Set<UUID> = []
    /// Chats that started running but haven't been saved yet, so they show
    /// in the sidebar while their first turn is still going.
    var provisionalSummaries: [SessionSummary] = []

    @ObservationIgnored let store = SessionStore()
    @ObservationIgnored private let projectStore = ProjectStore()
    @ObservationIgnored private let taskStore = ScheduledTaskStore()
    @ObservationIgnored private var schedulerTimer: Timer?
    @ObservationIgnored private let launchedAt = Date()
    @ObservationIgnored private let keychain = KeychainStore()
    @ObservationIgnored private var controllers: [UUID: SessionController] = [:]

    init() {
        settings = AppSettings.load()
        summaries = store.list()
        projects = projectStore.load()
        expandedProjects = Set(projects.map(\.id))
        tasks = taskStore.load()
        // Runs that were going when the app last quit didn't finish.
        for index in tasks.indices {
            for run in tasks[index].runs where run.status == .running {
                var stopped = run
                stopped.status = .stopped
                stopped.summary = "Apeiron quit before the run finished."
                tasks[index].record(stopped)
            }
        }
        refreshKeyPresence()
        newSession()
        startScheduler()
    }

    // MARK: Sessions

    var currentController: SessionController? {
        selection.flatMap { controller(for: $0) }
    }

    func controller(for id: UUID) -> SessionController? {
        if let controller = controllers[id] { return controller }
        guard let session = store.load(id) else { return nil }
        let controller = SessionController(session: session, app: self)
        controllers[id] = controller
        return controller
    }

    /// Opens a fresh chat, reusing an untouched one if it's already open.
    /// Pass a project to start the chat inside it.
    func newSession(workspace: URL? = nil, project: Project? = nil) {
        route = .chat
        if let current = currentController, current.session.messages.isEmpty, !current.isRunning,
           current.session.scheduledTaskID == nil {
            if current.session.projectID == project?.id {
                if let workspace { current.setWorkspace(workspace) }
                return
            }
            // Drop the untouched chat; it was never saved.
            controllers[current.id] = nil
        }
        let session: Session
        if let project {
            let modelID = project.defaultModelID.flatMap { model(id: $0)?.id } ?? settings.defaultModelID
            session = Session(
                workspacePath: (workspace ?? self.workspace(for: project)).path,
                modelID: modelID,
                mode: project.defaultMode,
                projectID: project.id
            )
            expandedProjects.insert(project.id)
        } else {
            let carried = currentController?.session.projectID == nil ? currentController?.workspaceURL : nil
            let path = (workspace ?? carried ?? lastWorkspace)?.path
            session = Session(workspacePath: path, modelID: settings.defaultModelID, mode: settings.defaultMode)
        }
        let controller = SessionController(session: session, app: self)
        controllers[session.id] = controller
        selection = session.id
        if let workspace = session.workspacePath, project != nil {
            controller.checkWorkspaceAccess(URL(fileURLWithPath: workspace))
        }
    }

    func showTasks() {
        route = .tasks
    }

    func open(_ id: UUID) {
        route = .chat
        selection = id
    }

    /// Lets a chat show in the sidebar as soon as it starts running.
    func noteStarted(_ session: Session) {
        guard !summaries.contains(where: { $0.id == session.id }),
              !provisionalSummaries.contains(where: { $0.id == session.id }) else { return }
        var summary = session.summary
        summary.updatedAt = Date()
        provisionalSummaries.append(summary)
    }

    /// Saved chats plus ones still on their first turn, newest first.
    var allSummaries: [SessionSummary] {
        let saved = Set(summaries.map(\.id))
        return (summaries + provisionalSummaries.filter { !saved.contains($0.id) })
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// How many chats are working right now, across every project.
    var runningCount: Int {
        allSummaries.filter { isRunning($0.id) }.count
    }

    func isRunning(_ id: UUID) -> Bool {
        controllers[id]?.isRunning ?? false
    }

    func didUpdate(_ session: Session) {
        do {
            try store.save(session)
        } catch {
            NSLog("Apeiron: failed to save session: \(error)")
        }
        summaries = store.list()
        provisionalSummaries.removeAll { $0.id == session.id }
    }

    func delete(_ id: UUID) {
        controllers[id]?.stop()
        controllers[id] = nil
        store.delete(id)
        summaries = store.list()
        provisionalSummaries.removeAll { $0.id == id }
        if selection == id {
            selection = nil
            newSession()
        }
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let controller = controller(for: id) else { return }
        controller.session.title = trimmed
        didUpdate(controller.session)
    }

    func togglePin(_ id: UUID) {
        guard let controller = controller(for: id) else { return }
        controller.session.isPinned.toggle()
        didUpdate(controller.session)
    }

    var filteredSummaries: [SessionSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return allSummaries }
        return allSummaries.filter {
            $0.title.lowercased().contains(query) || ($0.workspacePath?.lowercased().contains(query) ?? false)
        }
    }

    // MARK: Workspaces

    var lastWorkspace: URL? {
        settings.recentWorkspaces.first.map { URL(fileURLWithPath: $0) }
    }

    /// Projects shown in the sidebar: recent folders, most recent first.
    var workspaces: [URL] {
        var seen = Set<String>()
        var paths: [String] = []
        for path in settings.recentWorkspaces + allSummaries.compactMap(\.workspacePath) where seen.insert(path).inserted {
            paths.append(path)
        }
        return paths.prefix(12).map { URL(fileURLWithPath: $0) }
    }

    func defaultWorkspace() -> URL {
        if let last = lastWorkspace, FileManager.default.fileExists(atPath: last.path) { return last }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let scratch = home.appendingPathComponent("Apeiron")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }

    func noteWorkspace(_ url: URL) {
        var recents = settings.recentWorkspaces.filter { $0 != url.path }
        recents.insert(url.path, at: 0)
        settings.recentWorkspaces = Array(recents.prefix(20))
    }

    func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a project folder for Apeiron to work in"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        noteWorkspace(url)
        return url
    }

    func openFolderInNewChat() {
        guard let url = chooseFolder() else { return }
        if let current = currentController, current.session.messages.isEmpty {
            current.setWorkspace(url)
        } else {
            newSession(workspace: url)
            currentController?.setWorkspace(url)
        }
    }

    func forgetWorkspace(_ url: URL) {
        settings.recentWorkspaces.removeAll { $0 == url.path }
    }

    // MARK: Models and keys

    var allModels: [ModelDescriptor] {
        ModelCatalog.builtIn + settings.customModels
    }

    func model(id: String) -> ModelDescriptor? {
        ModelCatalog.model(id: id, custom: settings.customModels)
    }

    func findModel(matching query: String) -> ModelDescriptor? {
        let needle = query.lowercased()
        return allModels.first { $0.id.lowercased() == needle || $0.apiModel.lowercased() == needle }
            ?? allModels.first { $0.displayName.lowercased().contains(needle) || $0.apiModel.lowercased().contains(needle) }
    }

    func isConfigured(_ provider: ProviderKind) -> Bool {
        !provider.requiresAPIKey || (keyPresence[provider] ?? false)
    }

    func apiKey(for provider: ProviderKind) -> String {
        if let key = keychain.get(provider.rawValue), !key.isEmpty { return key }
        return ProcessInfo.processInfo.environment[provider.environmentKey] ?? ""
    }

    func setAPIKey(_ key: String, for provider: ProviderKind) {
        keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.rawValue)
        refreshKeyPresence()
        controllers.values.forEach { $0.invalidateAgent() }
    }

    func refreshKeyPresence() {
        var presence: [ProviderKind: Bool] = [:]
        for provider in ProviderKind.allCases {
            presence[provider] = !apiKey(for: provider).isEmpty
        }
        keyPresence = presence
    }

    var hasAnyKey: Bool {
        ProviderKind.allCases.contains { $0.requiresAPIKey && (keyPresence[$0] ?? false) }
    }

    func makeProvider(for model: ModelDescriptor) throws -> LLMProvider {
        let key = apiKey(for: model.provider)
        if model.provider.requiresAPIKey && key.isEmpty {
            throw ProviderError.missingAPIKey(model.provider.displayName)
        }
        let baseURL = settings.baseURLOverrides[model.provider.rawValue].flatMap { URL(string: $0) }
        return ProviderFactory.make(for: model, apiKey: key, baseURL: baseURL)
    }

    // MARK: OpenRouter

    /// Fetches OpenRouter's model list once per launch (or on demand).
    func loadOpenRouterCatalog(force: Bool = false) async {
        guard force || openRouterEntries.isEmpty, !openRouterLoading else { return }
        openRouterLoading = true
        openRouterError = nil
        defer { openRouterLoading = false }
        do {
            let baseURL = settings.baseURLOverrides[ProviderKind.openRouter.rawValue].flatMap { URL(string: $0) }
            openRouterEntries = try await OpenRouterCatalog.fetch(apiKey: apiKey(for: .openRouter), baseURL: baseURL)
        } catch {
            openRouterError = error.localizedDescription
        }
    }

    func isInModelList(_ model: ModelDescriptor) -> Bool {
        allModels.contains { $0.id == model.id }
    }

    /// Adds an OpenRouter model to the picker, or removes one you added.
    func toggleModelInList(_ model: ModelDescriptor) {
        if settings.customModels.contains(where: { $0.id == model.id }) {
            settings.customModels.removeAll { $0.id == model.id }
        } else if !ModelCatalog.builtIn.contains(where: { $0.id == model.id }) {
            settings.customModels.append(model)
        }
    }

    func addAllowRule(_ rule: PermissionRule) {
        guard !settings.rules.allow.contains(rule) else { return }
        // Avoid rebuilding running agents: the live agent already added it.
        var updated = settings
        updated.rules.allow.append(rule)
        settings = updated
    }

    // MARK: Projects

    func project(id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    /// The folder a project's chats run in: its first linked folder, or a
    /// scratch folder named after the project.
    func workspace(for project: Project) -> URL {
        if let folder = project.primaryFolder { return folder }
        let safe = project.name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Apeiron/Projects/\(safe.isEmpty ? project.id.uuidString : safe)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Chats in a project, newest first.
    func sessions(in projectID: UUID) -> [SessionSummary] {
        filteredSummaries.filter { $0.projectID == projectID }
    }

    func beginNewProject() {
        let accents = AccentChoice.allCases
        let color = accents[projects.count % accents.count].rawValue
        projectDraft = ProjectDraft(project: Project(name: "", colorName: color), isNew: true)
    }

    func beginEditing(_ project: Project) {
        projectDraft = ProjectDraft(project: project, isNew: false)
    }

    func saveProject(_ project: Project) {
        var updated = project
        updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.name.isEmpty { updated.name = "Untitled project" }
        updated.updatedAt = Date()
        let isNew = !projects.contains { $0.id == updated.id }
        if let index = projects.firstIndex(where: { $0.id == updated.id }) {
            projects[index] = updated
        } else {
            projects.append(updated)
        }
        persistProjects()
        expandedProjects.insert(updated.id)
        // Chats pick up new folders and instructions on their next message.
        for controller in controllers.values where controller.session.projectID == updated.id {
            controller.invalidateAgent()
        }
        if isNew { newSession(project: updated) }
    }

    func deleteProject(_ id: UUID, deletingChats: Bool) {
        for summary in allSummaries where summary.projectID == id {
            if deletingChats {
                delete(summary.id)
            } else {
                move(summary.id, to: nil)
            }
        }
        projects.removeAll { $0.id == id }
        for index in tasks.indices where tasks[index].projectID == id {
            tasks[index].projectID = nil
            tasks[index].isEnabled = false
        }
        persistTasks()
        persistProjects()
    }

    /// Moves a chat into a project, or out of every project with nil.
    func move(_ sessionID: UUID, to projectID: UUID?) {
        guard let controller = controller(for: sessionID) else { return }
        controller.session.projectID = projectID
        controller.invalidateAgent()
        if controller.session.messages.isEmpty {
            controller.assign(to: projectID.flatMap { project(id: $0) })
        } else {
            didUpdate(controller.session)
        }
        if let projectID { expandedProjects.insert(projectID) }
    }

    func toggleExpanded(_ projectID: UUID) {
        if expandedProjects.contains(projectID) {
            expandedProjects.remove(projectID)
        } else {
            expandedProjects.insert(projectID)
        }
    }

    func chooseItems() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Link"
        panel.message = "Choose folders and files for this project. Apeiron gets full access to them."
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    private func persistProjects() {
        do {
            try projectStore.save(projects)
        } catch {
            NSLog("Apeiron: failed to save projects: \(error)")
        }
    }

    // MARK: Scheduled tasks

    func task(id: UUID) -> ScheduledTask? {
        tasks.first { $0.id == id }
    }

    func beginNewTask(in project: Project? = nil) {
        taskDraft = ScheduledTask(
            name: "",
            projectID: project?.id ?? currentController?.session.projectID,
            workspacePath: project == nil ? currentController?.workspaceURL?.path : nil
        )
    }

    func saveTask(_ task: ScheduledTask) {
        var updated = task
        updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.name.isEmpty { updated.name = Session.title(from: updated.prompt) }
        if let index = tasks.firstIndex(where: { $0.id == updated.id }) {
            tasks[index] = updated
        } else {
            tasks.append(updated)
        }
        persistTasks()
        if updated.notify { requestNotificationPermission() }
    }

    func deleteTask(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        persistTasks()
    }

    func setTaskEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].isEnabled = enabled
        persistTasks()
    }

    func startScheduler() {
        schedulerTimer?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickScheduler() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        schedulerTimer = timer
    }

    /// Starts every task whose fire time has passed since it last ran. Tasks
    /// only fire while Apeiron is open; missed runs aren't replayed.
    func tickScheduler(now: Date = Date()) {
        for task in tasks where task.isDue(at: now, since: launchedAt) {
            runTask(task.id, trigger: .schedule, now: now)
        }
    }

    /// Runs a task in a fresh chat. Returns the new chat's id.
    @discardableResult
    func runTask(_ taskID: UUID, trigger: ScheduledTaskRun.Trigger = .manual, now: Date = Date()) -> UUID? {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return nil }
        let task = tasks[index]
        // One run at a time; a fire time that lands mid-run is skipped.
        guard !runningTaskIDs.contains(task.id) else {
            tasks[index].lastRunAt = now
            persistTasks()
            return nil
        }
        let project = task.projectID.flatMap { self.project(id: $0) }
        let workspace = project.map { self.workspace(for: $0) }
            ?? task.workspacePath.map { URL(fileURLWithPath: $0) }
            ?? defaultWorkspace()
        let modelID = [task.modelID, project?.defaultModelID].compactMap { $0 }.first { model(id: $0) != nil }
            ?? settings.defaultModelID
        let stamp = now.formatted(date: .abbreviated, time: .shortened)
        let session = Session(
            title: "\(task.name) · \(stamp)",
            workspacePath: workspace.path,
            modelID: modelID,
            mode: task.mode,
            projectID: project?.id,
            scheduledTaskID: task.id
        )
        let controller = SessionController(session: session, app: self)
        controller.autoDenyApprovals = task.approvalPolicy == .deny
        controllers[session.id] = controller

        let run = ScheduledTaskRun(sessionID: session.id, startedAt: now, trigger: trigger)
        tasks[index].lastRunAt = now
        tasks[index].record(run)
        runningTaskIDs.insert(task.id)
        persistTasks()

        controller.onRunFinished = { [weak self] controller in
            self?.finishTaskRun(taskID: task.id, runID: run.id, controller: controller)
        }
        controller.send(task.prompt)
        if let projectID = project?.id { expandedProjects.insert(projectID) }
        return session.id
    }

    private func finishTaskRun(taskID: UUID, runID: UUID, controller: SessionController) {
        controller.onRunFinished = nil
        runningTaskIDs.remove(taskID)
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              var run = tasks[index].runs.first(where: { $0.id == runID }) else { return }
        run.finishedAt = Date()
        if let error = controller.errorBanner {
            run.status = .failed
            run.summary = error
        } else if controller.wasStopped {
            run.status = .stopped
        } else {
            run.status = .succeeded
            run.summary = controller.lastAssistantText.map { String($0.prefix(400)) }
        }
        tasks[index].record(run)
        persistTasks()
        if tasks[index].notify {
            notify(title: tasks[index].name, body: run.status == .succeeded
                ? (run.summary.map { String($0.prefix(160)) } ?? "Finished.")
                : (run.summary ?? "The run \(run.status.rawValue)."))
        }
    }

    private func persistTasks() {
        do {
            try taskStore.save(tasks)
        } catch {
            NSLog("Apeiron: failed to save tasks: \(error)")
        }
    }

    /// Notifications need an app bundle; `swift run` has none.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    private func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    var userFirstName: String? {
        NSFullUserName().split(separator: " ").first.map(String.init)
    }
}


/// A project in the editor sheet.
struct ProjectDraft: Identifiable {
    var project: Project
    var isNew: Bool
    var id: UUID { project.id }
}
