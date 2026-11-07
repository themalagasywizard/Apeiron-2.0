import ApeironKit
import SwiftUI

struct SessionView: View {
    var controller: SessionController
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.canvas.ignoresSafeArea()

            if controller.isEmpty {
                EmptyStateView(controller: controller)
            } else {
                TranscriptView(controller: controller)
            }

            if !controller.isEmpty {
                bottomStack
            }
        }
        .overlay(alignment: .top) { TopBarScrim() }
        .background(
            Button("") { if controller.pendingApprovals.isEmpty { controller.stop() } }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .disabled(!controller.isRunning || !controller.pendingApprovals.isEmpty)
        )
    }

    private var bottomStack: some View {
        VStack(spacing: 10) {
            if let banner = controller.errorBanner {
                ErrorBanner(message: banner, controller: controller)
            }
            if let approval = controller.pendingApprovals.first {
                ApprovalView(approval: approval, queued: controller.pendingApprovals.count - 1) { reply in
                    controller.resolve(approval, with: reply)
                }
                .id(approval.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if controller.isRunning {
                StatusLine(controller: controller)
                    .transition(.opacity)
            }
            ComposerView(controller: controller)
        }
        .frame(maxWidth: Metrics.transcriptWidth)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .padding(.top, 28)
        .background(
            LinearGradient(
                colors: [Palette.canvas.opacity(0), Palette.canvas, Palette.canvas],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
        .animation(Motion.snappy, value: controller.pendingApprovals.first?.id)
        .animation(Motion.snappy, value: controller.isRunning)
    }
}

struct StatusLine: View {
    var controller: SessionController
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ApeironMark(size: 16, isActive: true)
            Text(controller.statusText ?? "Working")
                .font(theme.ui(12.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
            Spacer()
            if let todo = controller.todos.first(where: { $0.status == .inProgress }) {
                Text(todo.activeForm ?? todo.content)
                    .font(theme.ui(12))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                KeyCap(text: "esc")
                Text("to stop").font(theme.ui(11.5)).foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, 6)
        .animation(Motion.fade, value: controller.statusText)
    }
}

struct ErrorBanner: View {
    var message: String
    var controller: SessionController
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
            Text(message)
                .font(theme.ui(13))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if message.contains("API key") {
                Button("Open Settings") { openSettings() }
                    .buttonStyle(AccentButtonStyle(compact: true))
            } else if message.contains("macOS blocked access") {
                if !FileAccess.isSandboxed {
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(AccentButtonStyle(compact: true))
                }
                Button("Check again") {
                    if let url = controller.workspaceURL { controller.checkWorkspaceAccess(url) }
                }
                .buttonStyle(OutlineButtonStyle(compact: true))
            } else {
                Button("Retry") { controller.retryLast() }
                    .buttonStyle(OutlineButtonStyle(compact: true))
            }
            Button {
                controller.errorBanner = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(GhostButtonStyle())
            .foregroundStyle(Palette.textTertiary)
        }
        .padding(12)
        .card(highlighted: Palette.warning.opacity(0.6), fill: Palette.surfaceRaised)
    }
}

struct TranscriptView: View {
    var controller: SessionController
    @Environment(\.theme) private var theme
    @State private var followTail = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    TranscriptHeader(controller: controller)
                        .padding(.bottom, 8)
                    ForEach(controller.items) { item in
                        row(item)
                            .id(item.id)
                    }
                    Color.clear
                        .frame(height: 220)
                        .id("bottom")
                        .onAppear { followTail = true }
                        .onDisappear { followTail = false }
                }
                .frame(maxWidth: Metrics.transcriptWidth)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: controller.id) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: controller.scrollTick) { _, _ in
                guard followTail || controller.isRunning else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: TranscriptItem) -> some View {
        switch item {
        case .user(let user):
            UserMessageView(item: user) { text in
                controller.draft = text
            }
            .padding(.top, 6)
        case .assistant(let model):
            AssistantTextView(model: model)
        case .thinking(let model):
            ThinkingView(model: model)
        case .tool(let model):
            ToolCardView(model: model)
        case .notice(let notice):
            NoticeView(item: notice)
        }
    }
}

/// Session title and context shown at the top of a transcript.
struct TranscriptHeader: View {
    var controller: SessionController
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(controller.session.title)
                .font(theme.display(24))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let project = controller.project {
                    ProjectGlyph(project: project, size: 14)
                    Text(project.name)
                    Text("·")
                }
                Image(systemName: "folder")
                Text(controller.workspaceName)
                Text("·")
                Text(controller.model.displayName)
                Text("·")
                Image(systemName: controller.session.mode.symbol)
                Text(controller.session.mode.label)
            }
            .font(theme.ui(12))
            .foregroundStyle(Palette.textTertiary)
        }
    }
}
