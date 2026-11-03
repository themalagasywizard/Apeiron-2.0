import ApeironKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Button { app.newSession() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.accentColor)
                        Text("New chat")
                            .font(theme.ui(13, weight: .medium))
                            .foregroundStyle(Palette.textPrimary)
                        Spacer()
                        KeyCap(text: "⌘N")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(GhostButtonStyle(padding: EdgeInsets()))

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
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 8)

            List(selection: $app.selection) {
                if !app.workspaces.isEmpty && app.searchText.isEmpty {
                    Section {
                        ForEach(app.workspaces.prefix(6), id: \.path) { url in
                            ProjectRow(url: url)
                        }
                    } header: {
                        sectionHeader("Projects") {
                            app.openFolderInNewChat()
                        }
                    }
                }

                let pinned = app.filteredSummaries.filter(\.isPinned)
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
                    ForEach(app.filteredSummaries.filter { !$0.isPinned }) { summary in
                        sessionRow(summary)
                    }
                    if app.summaries.isEmpty {
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
    }

    private func sectionHeader(_ title: String, action: (() -> Void)?) -> some View {
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
                .help("Open a folder")
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
                    Button("Export as Markdown…") {
                        app.selection = summary.id
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

private struct ProjectRow: View {
    var url: URL
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        Button { app.newSession(workspace: url) } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textTertiary)
                Text(url.lastPathComponent)
                    .font(theme.ui(13))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New chat in \(url.path)")
        .contextMenu {
            Button("New chat here") { app.newSession(workspace: url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Remove from list") { app.forgetWorkspace(url) }
        }
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
