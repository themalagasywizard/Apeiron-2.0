import ApeironKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var app = app
        let theme = app.settings.theme
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
            } detail: {
                detail
                    .background(Palette.canvas.ignoresSafeArea())
                    .toolbar {
                        ToolbarItem(placement: .navigation) { Breadcrumb() }
                        ToolbarItem(placement: .primaryAction) { TopBarTools() }
                    }
                    .toolbarBackground(.hidden, for: .windowToolbar)
            }
            .navigationTitle(windowTitle)

            if app.showCommandPalette {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { app.showCommandPalette = false }
                    .transition(.opacity)
                VStack {
                    CommandPaletteView()
                        .padding(.top, 90)
                    Spacer()
                }
                .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: app.showCommandPalette)
        .sheet(isPresented: $app.showOpenRouterBrowser) {
            OpenRouterBrowser()
                .environment(app)
                .environment(\.theme, theme)
                .tint(theme.accentColor)
        }
        .sheet(item: $app.projectDraft) { draft in
            ProjectEditorView(project: draft.project, isNew: draft.isNew)
                .environment(app)
                .environment(\.theme, theme)
                .tint(theme.accentColor)
        }
        .sheet(item: $app.taskDraft) { task in
            TaskEditorView(task: task)
                .environment(app)
                .environment(\.theme, theme)
                .tint(theme.accentColor)
        }
        .environment(\.theme, theme)
        .tint(theme.accentColor)
        .frame(minWidth: 860, minHeight: 560)
        .onChange(of: app.selection) { _, new in
            if new == nil && app.route == .chat { app.newSession() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        @Bindable var app = app
        switch app.route {
        case .tasks:
            TasksView()
        case .chat:
            if let controller = app.currentController {
                SessionView(controller: controller)
                    .id(controller.id)
                    .inspector(isPresented: $app.showInspector) {
                        InspectorView(controller: controller)
                            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                    }
            } else {
                Palette.canvas
            }
        }
    }

    private var windowTitle: String {
        switch app.route {
        case .tasks: return "Tasks"
        case .chat: return app.currentController?.session.title ?? "Apeiron"
        }
    }
}

/// Fades content out under the transparent toolbar so it reads as one
/// continuous surface with the canvas instead of a grey strip.
struct TopBarScrim: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Palette.canvas, location: 0),
                .init(color: Palette.canvas.opacity(0.92), location: 0.55),
                .init(color: Palette.canvas.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 30)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}

/// Left side of the top bar: where you are (project › chat, or Tasks).
private struct Breadcrumb: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 7) {
            switch app.route {
            case .tasks:
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                Text("Tasks")
                    .font(theme.ui(13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                if !app.tasks.isEmpty {
                    Text("\(app.tasks.filter(\.isEnabled).count) active")
                        .font(theme.ui(12))
                        .foregroundStyle(Palette.textTertiary)
                }
            case .chat:
                if let controller = app.currentController {
                    if let project = controller.project {
                        Button {
                            app.beginEditing(project)
                        } label: {
                            HStack(spacing: 6) {
                                ProjectGlyph(project: project, size: 16)
                                Text(project.name)
                                    .font(theme.ui(13, weight: .medium))
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Project settings")
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.textTertiary)
                    }
                    if controller.session.scheduledTaskID != nil {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.textTertiary)
                            .help("Started by a scheduled task")
                    }
                    Text(controller.isEmpty ? "New chat" : controller.session.title)
                        .font(theme.ui(13, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 360, alignment: .leading)
                    if controller.isRunning {
                        ApeironMark(size: 11, isActive: true)
                            .transition(.opacity)
                    }
                }
            }
        }
        .padding(.leading, 6)
        .animation(Motion.fade, value: app.currentController?.isRunning)
    }
}

/// Running chats, context gauge, command palette and inspector in one pill.
private struct TopBarTools: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if app.runningCount > 0 {
                RunningMenu()
            }
            HStack(spacing: 2) {
                if app.route == .chat, let controller = app.currentController, let usage = controller.usage, usage.contextTokens > 0 {
                    ContextToolbarGauge(usage: usage)
                        .padding(.horizontal, 8)
                    PillDivider()
                }
                if app.route == .tasks {
                    TopBarButton(systemImage: "plus", help: "New task") { app.beginNewTask() }
                    PillDivider()
                }
                TopBarButton(systemImage: "command", help: "Command palette (⌘K)") {
                    app.showCommandPalette.toggle()
                }
                if app.route == .chat {
                    TopBarButton(systemImage: "sidebar.right", help: "Toggle inspector (⌥⌘I)", isOn: app.showInspector) {
                        withAnimation(Motion.snappy) { app.showInspector.toggle() }
                    }
                }
            }
            .padding(2)
            .background(
                Capsule(style: .continuous)
                    .fill(Palette.surface.opacity(0.7))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Palette.border.opacity(0.9), lineWidth: 0.5)
            )
            .shadow(color: Palette.shadow.opacity(0.5), radius: 3, y: 1)
        }
        .animation(Motion.snappy, value: app.runningCount)
    }
}

private struct PillDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(width: 1, height: 14)
            .padding(.horizontal, 2)
    }
}

private struct TopBarButton: View {
    var systemImage: String
    var help: String
    var isOn = false
    var action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? theme.accentColor : (hovering ? Palette.textPrimary : Palette.textSecondary))
                .frame(width: 28, height: 24)
                .background(
                    Capsule(style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        .help(help)
    }
}

/// "2 running" — jump to any chat that's working right now.
private struct RunningMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let running = app.allSummaries.filter { app.isRunning($0.id) }
        Menu {
            ForEach(running) { summary in
                Button {
                    app.open(summary.id)
                } label: {
                    let project = summary.projectID.flatMap { app.project(id: $0) }?.name
                    Text(project.map { "\($0) › \(summary.title)" } ?? summary.title)
                }
            }
        } label: {
            HStack(spacing: 6) {
                ApeironMark(size: 11, isActive: true)
                Text("\(running.count) running")
                    .font(theme.ui(11.5, weight: .medium))
                    .foregroundStyle(theme.accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(theme.accentColor.opacity(0.12)))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Chats working right now")
    }
}

/// A small ring showing how full the context window is.
private struct ContextToolbarGauge: View {
    var usage: UsageSnapshot
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            RingGauge(fraction: usage.contextFraction, lineWidth: 2.5, tint: tint)
                .frame(width: 13, height: 13)
            Text("\(Int((usage.contextFraction * 100).rounded()))%")
                .font(theme.mono(11, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
        }
        .help("\(usage.contextTokens.compactTokens) of \(usage.contextWindow.compactTokens) tokens in context")
    }

    private var tint: Color {
        let ratio = Double(usage.contextTokens) / Double(max(1, usage.compactAt))
        if ratio > 0.9 { return Palette.danger }
        if ratio > 0.7 { return Palette.warning }
        return theme.accentColor
    }
}
