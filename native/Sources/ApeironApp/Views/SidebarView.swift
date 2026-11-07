import ApeironKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var projectPendingDelete: Project?

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                NavRow(icon: "square.and.pencil", title: "New chat", shortcut: "⌘N", isActive: false, tint: theme.accentColor) {
                    app.newSession()
                }
                NavRow(
                    icon: "clock.arrow.circlepath",
                    title: "Tasks",
                    badge: taskBadge,
                    isActive: app.route == .tasks
                ) {
                    app.showTasks()
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.textTertiary)
                    TextField("Search", text: $app.searchText)
                        .textFieldStyle(.plain)
                        .font(theme.ui(12.5))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous).fill(Palette.hover))
                .padding(.top, 8)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 8)

            List(selection: chatSelection) {
                if app.searchText.isEmpty {
                    Section {
                        if app.projects.isEmpty {
                            Button { app.beginNewProject() } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus.rectangle.on.folder")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Palette.textTertiary)
                                    Text("Create a project")
                                        .font(theme.ui(12.5))
                                        .foregroundStyle(Palette.textSecondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(app.projects) { project in
                            ProjectRow(project: project) { projectPendingDelete = project }
                            if app.expandedProjects.contains(project.id) {
                                let chats = app.sessions(in: project.id)
                                ForEach(chats) { summary in
                                    sessionRow(summary)
                                        .padding(.leading, 20)
                                }
                                if chats.isEmpty {
                                    Button { app.newSession(project: project) } label: {
                                        Text("Start the first chat")
                                            .font(theme.ui(12))
                                            .foregroundStyle(Palette.textTertiary)
                                            .padding(.leading, 28)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    } header: {
                        sectionHeader("Projects", help: "New project") {
                            app.beginNewProject()
                        }
                    }
                }

                let loose = app.filteredSummaries.filter { app.searchText.isEmpty ? $0.projectID == nil || app.project(id: $0.projectID!) == nil : true }
                let pinned = loose.filter(\.isPinned)
                if !pinned.isEmpty {
                    Section {
                        ForEach(pinned) { summary in
                            sessionRow(summary)
                        }
                    } header: {
                        sectionHeader("Pinned", action: nil)
                    }
                }

                Section {
                    ForEach(loose.filter { !$0.isPinned }) { summary in
                        sessionRow(summary)
                    }
                    if app.allSummaries.isEmpty {
                        Text("Your chats will appear here.")
                            .font(theme.ui(12))
                            .foregroundStyle(Palette.textTertiary)
                            .padding(.vertical, 6)
                    }
                } header: {
                    sectionHeader(app.searchText.isEmpty ? "Recents" : "Results", action: nil)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            footer
        }
        .background(Palette.sidebar)
        .confirmationDialog(
            "Delete “\(projectPendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { projectPendingDelete != nil }, set: { if !$0 { projectPendingDelete = nil } }),
            presenting: projectPendingDelete
        ) { project in
            Button("Delete project, keep its chats") { app.deleteProject(project.id, deletingChats: false) }
            Button("Delete project and its chats", role: .destructive) { app.deleteProject(project.id, deletingChats: true) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Linked folders and files stay on disk. Scheduled tasks in this project are paused.")
        }
    }

    /// The list highlights a chat only while chats are showing.
    private var chatSelection: Binding<UUID?> {
        Binding(
            get: { app.route == .chat ? app.selection : nil },
            set: { new in if let new { app.open(new) } }
        )
    }

    private var taskBadge: String? {
        let running = app.runningTaskIDs.count
        if running > 0 { return "\(running) running" }
        let active = app.tasks.filter(\.isEnabled).count
        return active > 0 ? "\(active)" : nil
    }

    private func sectionHeader(_ title: String, help: String = "Open a folder", action: (() -> Void)?) -> some View {
        HStack {
            Text(title)
                .font(theme.ui(11, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
            Spacer()
            if let action {
                Button(action: action) {
                    Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textTertiary)
                .help(help)
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ summary: SessionSummary) -> some View {
        if renaming == summary.id {
            TextField("Title", text: $renameText)
                .textFieldStyle(.plain)
                .font(theme.ui(13))
                .onSubmit {
                    app.rename(summary.id, to: renameText)
                    renaming = nil
                }
                .onExitCommand { renaming = nil }
                .tag(summary.id)
        } else {
            SessionRow(summary: summary, isRunning: app.isRunning(summary.id))
                .tag(summary.id)
                .contextMenu {
                    Button("Rename") {
                        renameText = summary.title
                        renaming = summary.id
                    }
                    Button(summary.isPinned ? "Unpin" : "Pin") { app.togglePin(summary.id) }
                    if !app.projects.isEmpty || summary.projectID != nil {
                        Menu("Move to project") {
                            ForEach(app.projects) { project in
                                Button(project.name) { app.move(summary.id, to: project.id) }
                                    .disabled(summary.projectID == project.id)
                            }
                            if summary.projectID != nil {
                                Divider()
                                Button("Remove from project") { app.move(summary.id, to: nil) }
                            }
                        }
                    }
                    Button("Export as Markdown…") {
                        app.open(summary.id)
                        app.currentController?.exportMarkdown()
                    }
                    if let path = summary.workspacePath {
                        Button("Reveal folder in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { app.delete(summary.id) }
                }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(theme.accentColor.opacity(0.18))
                .frame(width: 26, height: 26)
                .overlay(
                    Text(String(app.userFirstName?.prefix(1) ?? "A"))
                        .font(theme.ui(12, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                )
            VStack(alignment: .leading, spacing: 0) {
                Text(app.userFirstName ?? "Apeiron")
                    .font(theme.ui(12.5, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                Text(app.hasAnyKey ? "Connected" : "No API key yet")
                    .font(theme.ui(11))
                    .foregroundStyle(app.hasAnyKey ? Palette.textTertiary : Palette.warning)
            }
            Spacer()
            Button { openSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 13))
            }
            .buttonStyle(GhostButtonStyle())
            .foregroundStyle(Palette.textSecondary)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
}

/// A top-level sidebar destination ("New chat", "Tasks").
private struct NavRow: View {
    var icon: String
    var title: String
    var shortcut: String? = nil
    var badge: String? = nil
    var isActive: Bool
    var tint: Color? = nil
    var action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint ?? (isActive ? theme.accentColor : Palette.textSecondary))
                    .frame(width: 18)
                Text(title)
                    .font(theme.ui(13, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(theme.ui(10.5, weight: .semibold))
                        .foregroundStyle(isActive ? theme.accentColor : Palette.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(isActive ? theme.accentColor.opacity(0.14) : Palette.hover))
                }
                if let shortcut { KeyCap(text: shortcut) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                    .fill(isActive ? Palette.selection : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(GhostButtonStyle(padding: EdgeInsets()))
    }
}

/// A project heading in the sidebar: expands to show its chats.
private struct ProjectRow: View {
    var project: Project
    var onDelete: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let expanded = app.expandedProjects.contains(project.id)
        let running = app.sessions(in: project.id).filter { app.isRunning($0.id) }.count
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Palette.textTertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            ProjectGlyph(project: project, size: 18)
            Text(project.name)
                .font(theme.ui(13, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if running > 0 && !hovering {
                HStack(spacing: 4) {
                    ApeironMark(size: 10, isActive: true)
                    Text("\(running)").font(theme.ui(11, weight: .medium)).foregroundStyle(Palette.textTertiary)
                }
                .help("\(running) chat\(running == 1 ? "" : "s") running")
            }
            if hovering {
                Button { app.newSession(project: project) } label: {
                    Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
                .help("New chat in \(project.name)")
                Button { app.beginEditing(project) } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
                .help("Project settings")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.snappy) { app.toggleExpanded(project.id) } }
        .onHover { hovering = $0 }
        .help(project.items.isEmpty ? project.name : project.items.map(\.path).joined(separator: "\n"))
        .contextMenu {
            Button("New chat") { app.newSession(project: project) }
            Button("Edit project…") { app.beginEditing(project) }
            Button("New scheduled task…") { app.beginNewTask(in: project) }
            if let folder = project.primaryFolder {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
            Divider()
            Button("Delete project…", role: .destructive, action: onDelete)
        }
    }
}

/// A project's coloured monogram.
struct ProjectGlyph: View {
    var project: Project
    var size: CGFloat = 18
    @Environment(\.theme) private var theme

    var color: Color {
        (AccentChoice(rawValue: project.colorName) ?? theme.accent).color
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color.opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(color.opacity(0.35), lineWidth: 0.5)
            )
            .overlay(
                Text(String(project.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.52, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
            )
            .frame(width: size, height: size)
    }
}

private struct SessionRow: View {
    var summary: SessionSummary
    var isRunning: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if isRunning {
                ApeironMark(size: 12, isActive: true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.title)
                    .font(theme.ui(13))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(theme.ui(11))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let time = summary.updatedAt.formatted(.relative(presentation: .named))
        if let path = summary.workspacePath {
            return "\(URL(fileURLWithPath: path).lastPathComponent) · \(time)"
        }
        return time
    }
}
