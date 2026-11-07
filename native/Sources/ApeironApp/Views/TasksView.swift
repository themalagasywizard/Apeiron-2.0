import ApeironKit
import SwiftUI

/// The Tasks tab: prompts Apeiron runs on a schedule, each run in a new chat.
struct TasksView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var pendingDelete: ScheduledTask?

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if app.tasks.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(sortedTasks) { task in
                                TaskCard(task: task) { pendingDelete = task }
                            }
                        }
                        footnote
                    }
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .top) { TopBarScrim() }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { task in
            Button("Delete task", role: .destructive) { app.deleteTask(task.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Chats from earlier runs are kept.")
        }
    }

    private var sortedTasks: [ScheduledTask] {
        app.tasks.sorted { a, b in
            if a.isEnabled != b.isEnabled { return a.isEnabled }
            let next = (a.nextRun() ?? .distantFuture, b.nextRun() ?? .distantFuture)
            return next.0 < next.1
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tasks")
                    .font(theme.display(30))
                    .foregroundStyle(Palette.textPrimary)
                Text("Prompts that run on a schedule. Every run opens a fresh chat you can read later.")
                    .font(theme.ui(13))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Button {
                app.beginNewTask()
            } label: {
                Label("New task", systemImage: "plus")
            }
            .buttonStyle(AccentButtonStyle())
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(theme.accentColor)
                Text("Automate the routine")
                    .font(theme.ui(15, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Start from a template or write your own. Tasks run while Apeiron is open.")
                    .font(theme.ui(12.5))
                    .foregroundStyle(Palette.textSecondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                ForEach(TaskTemplate.all) { template in
                    Button {
                        var task = ScheduledTask(name: template.name, prompt: template.prompt, schedule: template.schedule)
                        task.projectID = app.currentController?.session.projectID
                        task.workspacePath = task.projectID == nil ? app.currentController?.workspaceURL?.path : nil
                        app.taskDraft = task
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: template.icon)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(theme.accentColor)
                            Text(template.name)
                                .font(theme.ui(13, weight: .semibold))
                                .foregroundStyle(Palette.textPrimary)
                            Text((try? CronSchedule(template.schedule).summary) ?? template.schedule)
                                .font(theme.ui(11.5))
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .card(fill: Palette.surface)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .card(fill: Palette.surfaceSunken)
    }

    private var footnote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
            Text("Tasks run while Apeiron is open. A run that's due while the app is closed is skipped, not replayed.")
        }
        .font(theme.ui(11.5))
        .foregroundStyle(Palette.textTertiary)
    }
}

private struct TaskTemplate: Identifiable {
    var icon: String
    var name: String
    var prompt: String
    var schedule: String
    var id: String { name }

    static let all: [TaskTemplate] = [
        TaskTemplate(icon: "sun.horizon", name: "Morning briefing", prompt: "Look at what changed in this project since yesterday (git log, open TODOs, failing tests) and write me a short briefing of what needs attention today.", schedule: "0 9 * * 1-5"),
        TaskTemplate(icon: "checkmark.seal", name: "Nightly test run", prompt: "Run the project's test suite. If anything fails, investigate the cause and summarise what broke and the likely fix. Don't change any files.", schedule: "0 2 * * *"),
        TaskTemplate(icon: "shippingbox", name: "Weekly dependency check", prompt: "Check this project's dependencies for available updates and known vulnerabilities. Report what should be upgraded and why.", schedule: "0 10 * * 1"),
        TaskTemplate(icon: "doc.text.magnifyingglass", name: "Hourly log watch", prompt: "Scan the project's log files for new errors since the last hour and summarise anything unusual.", schedule: "0 * * * *"),
    ]
}

/// One task: schedule, where it runs, its switch and recent runs.
private struct TaskCard: View {
    var task: ScheduledTask
    var onDelete: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let isRunning = app.runningTaskIDs.contains(task.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                statusIcon(isRunning: isRunning)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(task.name)
                            .font(theme.ui(14, weight: .semibold))
                            .foregroundStyle(task.isEnabled ? Palette.textPrimary : Palette.textSecondary)
                            .lineLimit(1)
                        if isRunning {
                            HStack(spacing: 4) {
                                ApeironMark(size: 10, isActive: true)
                                Text("Running").font(theme.ui(11, weight: .medium))
                            }
                            .foregroundStyle(theme.accentColor)
                        }
                    }
                    metaLine
                    if !task.prompt.isEmpty {
                        Text(task.prompt)
                            .font(theme.ui(12.5))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    Button {
                        if let id = app.runTask(task.id) { app.open(id) }
                    } label: {
                        Label("Run now", systemImage: "play.fill")
                            .font(theme.ui(12, weight: .medium))
                    }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    .disabled(isRunning)
                    .opacity(isRunning ? 0.5 : 1)
                    Menu {
                        Button("Edit…") { app.taskDraft = task }
                        Button("Duplicate") {
                            var copy = task
                            copy.id = UUID()
                            copy.name = task.name + " copy"
                            copy.runs = []
                            copy.lastRunAt = nil
                            copy.createdAt = Date()
                            app.saveTask(copy)
                        }
                        Divider()
                        Button("Delete…", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(Palette.textSecondary)
                    Toggle("", isOn: Binding(get: { task.isEnabled }, set: { app.setTaskEnabled(task.id, $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .tint(theme.accentColor)
                        .help(task.isEnabled ? "Pause this task" : "Resume this task")
                }
            }
            .padding(16)

            if !task.runs.isEmpty {
                Divider().overlay(Palette.border)
                VStack(spacing: 0) {
                    ForEach(task.runs.prefix(3)) { run in
                        RunRow(run: run)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .card(highlighted: hovering ? Palette.borderStrong : nil, fill: Palette.surface)
        .shadow(color: Palette.shadow.opacity(hovering ? 1 : 0), radius: 12, y: 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { app.taskDraft = task }
        .animation(Motion.fade, value: hovering)
    }

    private func statusIcon(isRunning: Bool) -> some View {
        let tint = task.isEnabled ? theme.accentColor : Palette.textTertiary
        return Image(systemName: task.isEnabled ? "clock.arrow.circlepath" : "pause.circle")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.12)))
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
            Text(task.cron?.summary ?? "Invalid schedule")
                .foregroundStyle(task.cron == nil ? Palette.danger : Palette.textSecondary)
            if let next = task.nextRun() {
                Text("·")
                Text("next \(next.formatted(.relative(presentation: .named)))")
            } else if !task.isEnabled {
                Text("·")
                Text("Paused")
            }
            Text("·")
            if let project = task.projectID.flatMap({ app.project(id: $0) }) {
                ProjectGlyph(project: project, size: 13)
                Text(project.name)
            } else {
                Image(systemName: "folder")
                Text(task.workspacePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Default folder")
            }
        }
        .font(theme.ui(11.5))
        .foregroundStyle(Palette.textTertiary)
        .lineLimit(1)
    }
}

private struct RunRow: View {
    var run: ScheduledTaskRun
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button {
            app.open(run.sessionID)
        } label: {
            HStack(spacing: 10) {
                icon
                    .frame(width: 14)
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(theme.mono(11))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 150, alignment: .leading)
                Text(run.summary.map { $0.replacingOccurrences(of: "\n", with: " ") } ?? statusText)
                    .font(theme.ui(12))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                Spacer()
                if let finished = run.finishedAt {
                    Text(finished.timeIntervalSince(run.startedAt).shortDuration)
                        .font(theme.mono(11))
                        .foregroundStyle(Palette.textTertiary)
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                    .revealed(hovering)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open this run's chat")
    }

    private var statusText: String {
        switch run.status {
        case .running: return "Running…"
        case .succeeded: return "Finished"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch run.status {
        case .running: ApeironMark(size: 11, isActive: true)
        case .succeeded: Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.success)
        case .failed: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.danger)
        case .stopped: Image(systemName: "stop.circle").font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
        }
    }
}
