import AppKit
import ApeironKit
import Foundation
import Observation

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
    var keyPresence: [ProviderKind: Bool] = [:]

    @ObservationIgnored let store = SessionStore()
    @ObservationIgnored private let keychain = KeychainStore()
    @ObservationIgnored private var controllers: [UUID: SessionController] = [:]

    init() {
        settings = AppSettings.load()
        summaries = store.list()
        refreshKeyPresence()
        newSession()
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
    func newSession(workspace: URL? = nil) {
        if let current = currentController, current.session.messages.isEmpty, !current.isRunning {
            if let workspace { current.setWorkspace(workspace) }
            return
        }
        let path = (workspace ?? currentController?.workspaceURL ?? lastWorkspace)?.path
        let session = Session(workspacePath: path, modelID: settings.defaultModelID, mode: settings.defaultMode)
        let controller = SessionController(session: session, app: self)
        controllers[session.id] = controller
        selection = session.id
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
    }

    func delete(_ id: UUID) {
        controllers[id]?.stop()
        controllers[id] = nil
        store.delete(id)
        summaries = store.list()
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
        guard !query.isEmpty else { return summaries }
        return summaries.filter {
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
        for path in settings.recentWorkspaces + summaries.compactMap(\.workspacePath) where seen.insert(path).inserted {
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

    func addAllowRule(_ rule: PermissionRule) {
        guard !settings.rules.allow.contains(rule) else { return }
        // Avoid rebuilding running agents: the live agent already added it.
        var updated = settings
        updated.rules.allow.append(rule)
        settings = updated
    }

    var userFirstName: String? {
        NSFullUserName().split(separator: " ").first.map(String.init)
    }
}
