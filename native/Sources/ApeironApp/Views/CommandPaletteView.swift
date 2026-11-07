import ApeironKit
import SwiftUI

/// ⌘K: a fuzzy launcher for every action, model, mode and recent chat.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    struct Entry: Identifiable {
        var id: String
        var icon: String
        var title: String
        var detail: String = ""
        var group: String
        var shortcut: String?
        var run: @MainActor () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
                TextField("Search actions, models and chats", text: $query)
                    .textFieldStyle(.plain)
                    .font(theme.ui(15))
                    .focused($focused)
                    .onSubmit { runSelected() }
                    .onKeyPress(.upArrow) {
                        selection = max(0, selection - 1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        selection = min(max(0, results.count - 1), selection + 1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        close()
                        return .handled
                    }
                KeyCap(text: "esc")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().overlay(Palette.border)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let items = results
                        if items.isEmpty {
                            Text("No matches")
                                .font(theme.ui(13))
                                .foregroundStyle(Palette.textTertiary)
                                .padding(16)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                            if index == 0 || items[index - 1].group != entry.group {
                                Text(entry.group)
                                    .font(theme.ui(11, weight: .semibold))
                                    .foregroundStyle(Palette.textTertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, index == 0 ? 4 : 10)
                                    .padding(.bottom, 2)
                            }
                            row(entry, isSelected: index == selection)
                                .id(entry.id)
                                .onTapGesture {
                                    selection = index
                                    runSelected()
                                }
                                .onHover { if $0 { selection = index } }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 380)
                .onChange(of: selection) { _, new in
                    let items = results
                    guard items.indices.contains(new) else { return }
                    proxy.scrollTo(items[new].id)
                }
            }
        }
        .frame(width: 600)
        .background(
            RoundedRectangle(cornerRadius: Metrics.corner + 4, style: .continuous)
                .fill(Palette.surfaceRaised)
                .shadow(color: Palette.shadow.opacity(2.5), radius: 40, y: 18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner + 4, style: .continuous)
                .strokeBorder(Palette.border)
        )
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func row(_ entry: Entry, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.icon)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? theme.accentColor : Palette.textSecondary)
                .frame(width: 20)
            Text(entry.title)
                .font(theme.ui(13.5, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            if !entry.detail.isEmpty {
                Text(entry.detail)
                    .font(theme.ui(12))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if let shortcut = entry.shortcut {
                KeyCap(text: shortcut)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                .fill(isSelected ? Palette.selection : .clear)
        )
        .contentShape(Rectangle())
    }

    private func close() {
        app.showCommandPalette = false
    }

    private func runSelected() {
        let items = results
        guard items.indices.contains(selection) else { return }
        let entry = items[selection]
        close()
        // Let the palette dismiss before panels or popovers open.
        DispatchQueue.main.async { entry.run() }
    }

    // MARK: Entries

    private var results: [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = entries
        guard !needle.isEmpty else { return all.filter { $0.group != "Chats" || all.count < 40 } }
        return all
            .compactMap { entry -> (Entry, Int)? in
                guard let score = Self.fuzzyScore(needle, in: (entry.title + " " + entry.detail).lowercased()) else { return nil }
                return (entry, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private var entries: [Entry] {
        var list: [Entry] = []
        let controller = app.currentController

        list.append(Entry(id: "new", icon: "square.and.pencil", title: "New chat", group: "Actions", shortcut: "⌘N") { app.newSession() })
        list.append(Entry(id: "open", icon: "folder", title: "Open folder…", group: "Actions", shortcut: "⌘O") { app.openFolderInNewChat() })
        list.append(Entry(id: "new-project", icon: "plus.rectangle.on.folder", title: "New project…", group: "Actions", shortcut: "⇧⌘N") { app.beginNewProject() })
        list.append(Entry(id: "tasks", icon: "clock.arrow.circlepath", title: "Show tasks", detail: "Scheduled, automated prompts", group: "Actions", shortcut: "⇧⌘T") { app.showTasks() })
        list.append(Entry(id: "new-task", icon: "calendar.badge.plus", title: "New scheduled task…", group: "Actions") { app.beginNewTask() })
        list.append(Entry(id: "inspector", icon: "sidebar.right", title: app.showInspector ? "Hide inspector" : "Show inspector", group: "Actions", shortcut: "⌥⌘I") {
            app.showInspector.toggle()
        })
        if let controller {
            list.append(Entry(id: "compact", icon: "rectangle.compress.vertical", title: "Compact conversation", detail: "Summarise to free up context", group: "Actions") {
                controller.send("/compact")
            })
            list.append(Entry(id: "clear", icon: "eraser", title: "Clear conversation", group: "Actions") { controller.send("/clear") })
            list.append(Entry(id: "export", icon: "square.and.arrow.up", title: "Export as Markdown…", group: "Actions") { controller.exportMarkdown() })
            list.append(Entry(id: "init", icon: "text.badge.star", title: "Write APEIRON.md for this project", group: "Actions") { controller.send("/init") })
        }
        list.append(Entry(id: "openrouter", icon: "square.grid.2x2", title: "Browse OpenRouter models…", detail: "DeepSeek, GLM, Qwen, Claude…", group: "Actions") {
            app.showOpenRouterBrowser = true
        })
        list.append(Entry(id: "settings", icon: "gearshape", title: "Settings…", group: "Actions", shortcut: "⌘,") { openSettings() })

        if let controller {
            for mode in PermissionMode.allCases {
                list.append(Entry(
                    id: "mode-\(mode.rawValue)",
                    icon: mode.symbol,
                    title: "Mode: \(mode.label)",
                    detail: controller.session.mode == mode ? "current" : mode.summary,
                    group: "Permission mode"
                ) { controller.setMode(mode) })
            }
            for model in app.allModels where app.isConfigured(model.provider) {
                list.append(Entry(
                    id: "model-\(model.id)",
                    icon: model.id == controller.model.id ? "checkmark.circle.fill" : "cpu",
                    title: model.displayName,
                    detail: model.provider.displayName,
                    group: "Models"
                ) { controller.setModel(model) })
            }
            for command in controller.customCommands {
                list.append(Entry(id: "cmd-\(command.name)", icon: "command", title: "/\(command.name)", detail: command.description, group: "Project commands") {
                    controller.draft = "/\(command.name) "
                })
            }
        }

        for project in app.projects {
            list.append(Entry(id: "project-\(project.id)", icon: "folder", title: project.name, detail: "New chat in project", group: "Projects") {
                app.newSession(project: project)
            })
        }

        for task in app.tasks {
            list.append(Entry(id: "task-\(task.id)", icon: "play.circle", title: "Run “\(task.name)” now", detail: task.cron?.summary ?? "", group: "Tasks") {
                if let id = app.runTask(task.id) { app.open(id) }
            })
        }

        for summary in app.allSummaries.prefix(30) {
            let place = summary.projectID.flatMap { app.project(id: $0)?.name }
                ?? summary.workspacePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            list.append(Entry(id: "chat-\(summary.id)", icon: "bubble.left", title: summary.title, detail: place, group: "Chats") {
                app.open(summary.id)
            })
        }
        return list
    }

    /// Subsequence match: higher for contiguous runs and early matches.
    static func fuzzyScore(_ needle: String, in haystack: String) -> Int? {
        if haystack.contains(needle) {
            let offset = haystack.range(of: needle).map { haystack.distance(from: haystack.startIndex, to: $0.lowerBound) } ?? 0
            return 1000 - offset
        }
        var score = 0
        var run = 0
        var index = haystack.startIndex
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return nil }
            run = found == index ? run + 1 : 0
            score += 1 + run * 3
            index = haystack.index(after: found)
        }
        return score
    }
}
