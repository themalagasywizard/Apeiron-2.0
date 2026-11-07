import ApeironKit
import SwiftUI
import UniformTypeIdentifiers

/// Create or edit a project: a name, standing instructions, and the folders
/// and files every chat in it can read and edit.
struct ProjectEditorView: View {
    @State var project: Project
    var isNew: Bool
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var dropTargeted = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    nameField
                    itemsSection
                    instructionsSection
                    defaultsSection
                }
                .padding(24)
            }
            Divider().overlay(Palette.border)
            footer
        }
        .frame(width: 600, height: 680)
        .background(Palette.canvas)
        .onAppear { if isNew { nameFocused = true } }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            ProjectGlyph(project: displayProject, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? "New project" : "Project settings")
                    .font(theme.display(20))
                    .foregroundStyle(Palette.textPrimary)
                Text("Chats in a project share its folders, files and instructions, and can run side by side.")
                    .font(theme.ui(12))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Name")
            TextField("e.g. Marketing site", text: $project.name)
                .textFieldStyle(.plain)
                .font(theme.ui(15, weight: .medium))
                .focused($nameFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .card(fill: Palette.surface)
            HStack(spacing: 8) {
                ForEach(AccentChoice.allCases) { accent in
                    Button {
                        project.colorName = accent.rawValue
                    } label: {
                        Circle()
                            .fill(accent.color)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle()
                                    .strokeBorder(Palette.textPrimary.opacity(project.colorName == accent.rawValue ? 0.55 : 0), lineWidth: 1.5)
                                    .padding(-3)
                            )
                            .padding(3)
                    }
                    .buttonStyle(.plain)
                    .help(accent.name)
                }
            }
            .padding(.top, 2)
        }
    }

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                fieldLabel("Folders and files")
                Spacer()
                Button {
                    project.link(app.chooseItems())
                } label: {
                    Label("Add…", systemImage: "plus")
                }
                .buttonStyle(OutlineButtonStyle(compact: true))
            }
            VStack(spacing: 0) {
                if project.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(Palette.textTertiary)
                        Text("Drop folders or files here, or click Add.")
                            .font(theme.ui(12.5))
                            .foregroundStyle(Palette.textSecondary)
                        Text("Without a folder, chats run in ~/Apeiron/Projects/\(project.name.isEmpty ? "…" : project.name).")
                            .font(theme.ui(11.5))
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                } else {
                    ForEach(Array(project.items.enumerated()), id: \.element.id) { index, item in
                        itemRow(item, isPrimary: item.isDirectory && project.folders.first?.id == item.id)
                        if index < project.items.count - 1 {
                            Divider().overlay(Palette.border).padding(.leading, 40)
                        }
                    }
                }
            }
            .card(highlighted: dropTargeted ? theme.accentColor : nil, fill: Palette.surface)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock.open")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                Text("Apeiron gets full read and write access to everything linked here, in every chat of this project. The first folder is where commands run.")
                    .font(theme.ui(11.5))
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func itemRow(_ item: ProjectItem, isPrimary: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(theme.ui(13, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if isPrimary {
                        Text("Working folder")
                            .font(theme.ui(10, weight: .semibold))
                            .foregroundStyle(theme.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                    }
                    if !item.exists {
                        Text("Missing")
                            .font(theme.ui(10, weight: .semibold))
                            .foregroundStyle(Palette.danger)
                    }
                }
                Text(displayPath(item.path))
                    .font(theme.mono(11))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if item.isDirectory && !isPrimary {
                Button {
                    makePrimary(item)
                } label: {
                    Image(systemName: "arrow.up.to.line").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(GhostButtonStyle())
                .foregroundStyle(Palette.textTertiary)
                .help("Make this the working folder")
            }
            Button {
                project.items.removeAll { $0.id == item.id }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(GhostButtonStyle())
            .foregroundStyle(Palette.textTertiary)
            .help("Unlink")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Instructions")
            ZStack(alignment: .topLeading) {
                if project.instructions.isEmpty {
                    Text("What is this project about? How should Apeiron work here? Tone, conventions, things to avoid…")
                        .font(theme.ui(13))
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $project.instructions)
                    .font(theme.ui(13))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .frame(minHeight: 110)
            .card(fill: Palette.surface)
        }
    }

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("New chats")
            VStack(spacing: 0) {
                settingRow("Permission mode", detail: project.defaultMode.summary) {
                    Picker("", selection: $project.defaultMode) {
                        ForEach(PermissionMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider().overlay(Palette.border)
                settingRow("Model", detail: "Each chat can still switch models.") {
                    Picker("", selection: $project.defaultModelID) {
                        Text("App default").tag(String?.none)
                        Divider()
                        ForEach(app.allModels.filter { app.isConfigured($0.provider) }, id: \.id) { model in
                            Text(model.displayName).tag(Optional(model.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .card(fill: Palette.surface)
        }
    }

    private var footer: some View {
        HStack {
            if !isNew {
                Text("Changes apply to each chat from its next message.")
                    .font(theme.ui(11.5))
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(OutlineButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Create project" : "Save") {
                app.saveProject(project)
                dismiss()
            }
            .buttonStyle(AccentButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(project.name.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(project.name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: Helpers

    private var displayProject: Project {
        var copy = project
        if copy.name.isEmpty { copy.name = "P" }
        return copy
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(theme.ui(10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Palette.textTertiary)
    }

    private func settingRow<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(theme.ui(13, weight: .medium)).foregroundStyle(Palette.textPrimary)
                Text(detail).font(theme.ui(11.5)).foregroundStyle(Palette.textTertiary).lineLimit(2)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func makePrimary(_ item: ProjectItem) {
        project.items.removeAll { $0.id == item.id }
        project.items.insert(item, at: 0)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in project.link([url]) }
            }
        }
        return true
    }
}
