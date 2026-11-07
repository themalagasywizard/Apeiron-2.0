import ApeironKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Bindable var controller: SessionController
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var importing = false
    @State private var dropTargeted = false
    @State private var slashSelection = 0

    var body: some View {
        VStack(spacing: 0) {
            if !slashMatches.isEmpty {
                slashMenu
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            VStack(alignment: .leading, spacing: 8) {
                if !controller.attachments.isEmpty {
                    attachmentStrip
                }
                TextField(placeholder, text: $controller.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(theme.body(15))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1...12)
                    .focused($focused)
                    .onSubmit(submit)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        controller.draft += "\n"
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        guard let first = slashMatches.first else { return .ignored }
                        complete(first)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !slashMatches.isEmpty else { return .ignored }
                        slashSelection = max(0, slashSelection - 1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !slashMatches.isEmpty else { return .ignored }
                        slashSelection = min(slashMatches.count - 1, slashSelection + 1)
                        return .handled
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)

                HStack(spacing: 6) {
                    Button { importing = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(GhostButtonStyle(padding: EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2), cornerRadius: 11))
                    .help("Attach files or images")

                    ModePicker(controller: controller)
                    WorkspaceChip(controller: controller)

                    Spacer(minLength: 4)

                    ModelPicker(controller: controller)
                    sendButton
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Metrics.composerCorner, style: .continuous)
                    .fill(Palette.surface)
                    .shadow(color: Palette.shadow, radius: focused ? 22 : 14, y: focused ? 8 : 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.composerCorner, style: .continuous)
                    .strokeBorder(dropTargeted ? theme.accentColor : (focused ? Palette.borderStrong : Palette.border), lineWidth: dropTargeted ? 2 : 1)
            )
            .animation(Motion.fade, value: focused)
        }
        .animation(Motion.snappy, value: slashMatches.count)
        .onAppear { focused = true }
        .onChange(of: controller.id) { _, _ in focused = true }
        .onChange(of: controller.draft) { _, _ in slashSelection = 0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            addFiles(urls)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in addFiles([url]) }
                }
            }
            return true
        }
    }

    private var placeholder: String {
        if controller.isRunning { return "Apeiron is working… you can draft your next message" }
        if controller.items.isEmpty { return "How can I help?" }
        return "Reply to Apeiron…"
    }

    private var sendButton: some View {
        Group {
            if controller.isRunning {
                Button { controller.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Palette.selection))
                }
                .buttonStyle(.plain)
                .help("Stop (Esc)")
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(canSend ? theme.accent.onAccent : Palette.textTertiary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(canSend ? theme.accentColor : Palette.selection))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send (Return)")
            }
        }
        .animation(Motion.snappy, value: controller.isRunning)
    }

    private var canSend: Bool {
        !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controller.attachments.isEmpty
    }

    private func submit() {
        if let selected = slashMatches[safe: slashSelection], controller.draft.trimmingCharacters(in: .whitespaces) != "/" + selected.name {
            complete(selected)
            return
        }
        controller.submitDraft()
    }

    private func complete(_ command: SlashCommandInfo) {
        controller.draft = "/" + command.name + (command.argumentHint == nil ? "" : " ")
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let attachment = ComposerAttachment.load(from: url) {
                controller.attachments.append(attachment)
            }
        }
    }

    // MARK: Slash menu

    private var slashMatches: [SlashCommandInfo] {
        let draft = controller.draft
        guard draft.hasPrefix("/"), !draft.contains(" "), !draft.contains("\n") else { return [] }
        let query = draft.dropFirst().lowercased()
        return SlashCommands.all(custom: controller.customCommands).filter {
            query.isEmpty || $0.name.lowercased().hasPrefix(query)
        }
    }

    private var slashMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(slashMatches.prefix(8).enumerated()), id: \.element.id) { index, command in
                Button { complete(command) } label: {
                    HStack(spacing: 10) {
                        Text("/" + command.name)
                            .font(theme.mono(12.5, weight: .semibold))
                            .foregroundStyle(index == slashSelection ? theme.accentColor : Palette.textPrimary)
                        if let hint = command.argumentHint {
                            Text(hint).font(theme.mono(11.5)).foregroundStyle(Palette.textTertiary)
                        }
                        Spacer()
                        Text(command.summary)
                            .font(theme.ui(12))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                        if command.isCustom {
                            Text("custom").font(theme.ui(10.5, weight: .medium)).foregroundStyle(Palette.textTertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                            .fill(index == slashSelection ? Palette.selection : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .card(fill: Palette.surfaceRaised)
        .shadow(color: Palette.shadow, radius: 12, y: 4)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(controller.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachmentIcon(attachment))
                            .foregroundStyle(theme.accentColor)
                        Text(attachment.filename)
                            .lineLimit(1)
                            .foregroundStyle(Palette.textPrimary)
                        Button {
                            controller.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.textTertiary)
                    }
                    .font(theme.ui(12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .card(fill: Palette.surfaceSunken)
                }
            }
        }
    }

    private func attachmentIcon(_ attachment: ComposerAttachment) -> String {
        if case .image = attachment.kind { return "photo" }
        return "doc.text"
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Pickers

struct ModelPicker: View {
    var controller: SessionController
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var app = app
        Button { app.showModelPicker.toggle() } label: {
            ChipLabel(systemImage: nil, title: controller.model.displayName)
        }
        .buttonStyle(.plain)
        .help("Choose model")
        .popover(isPresented: $app.showModelPicker, arrowEdge: .bottom) {
            ModelPickerList(controller: controller)
        }
    }
}

struct ModelPickerList: View {
    var controller: SessionController
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(groups) { group in
                    let provider = group.provider
                    let models = group.models
                    HStack {
                        Text(provider.displayName.uppercased())
                            .font(theme.ui(10.5, weight: .semibold))
                            .foregroundStyle(Palette.textTertiary)
                            .tracking(0.6)
                        Spacer()
                        if !app.isConfigured(provider) {
                            Button("Add key") { openSettings() }
                                .buttonStyle(.plain)
                                .font(theme.ui(11, weight: .medium))
                                .foregroundStyle(theme.accentColor)
                        } else if provider == .openRouter {
                            Button("Browse all…") {
                                app.showModelPicker = false
                                app.showOpenRouterBrowser = true
                            }
                            .buttonStyle(.plain)
                            .font(theme.ui(11, weight: .medium))
                            .foregroundStyle(theme.accentColor)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                    ForEach(models) { model in
                        Button {
                            controller.setModel(model)
                            app.showModelPicker = false
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.displayName)
                                        .font(theme.ui(13, weight: .medium))
                                        .foregroundStyle(app.isConfigured(provider) ? Palette.textPrimary : Palette.textTertiary)
                                    if !model.tagline.isEmpty {
                                        Text(model.tagline)
                                            .font(theme.ui(11.5))
                                            .foregroundStyle(Palette.textTertiary)
                                    }
                                }
                                Spacer()
                                if !model.supportsTools {
                                    Text("chat only").font(theme.ui(10.5)).foregroundStyle(Palette.textTertiary)
                                }
                                if controller.model.id == model.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(theme.accentColor)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(GhostButtonStyle(padding: EdgeInsets()))
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 320)
        .frame(maxHeight: 460)
    }

    private struct ProviderGroup: Identifiable {
        var provider: ProviderKind
        var models: [ModelDescriptor]
        var id: String { provider.rawValue }
    }

    private var groups: [ProviderGroup] {
        let models = app.allModels
        return ProviderKind.allCases.compactMap { provider in
            let matching = models.filter { $0.provider == provider }
            return matching.isEmpty ? nil : ProviderGroup(provider: provider, models: matching)
        }
    }
}

struct ModePicker: View {
    var controller: SessionController
    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            ForEach(PermissionMode.allCases) { mode in
                Button {
                    controller.setMode(mode)
                } label: {
                    Label {
                        Text("\(mode.label) – \(mode.summary)")
                    } icon: {
                        Image(systemName: controller.session.mode == mode ? "checkmark" : mode.symbol)
                    }
                }
            }
        } label: {
            ChipLabel(systemImage: controller.session.mode.symbol, title: controller.session.mode.label, tint: tint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Permission mode (⌘⇧M to cycle)")
    }

    private var tint: Color? {
        switch controller.session.mode {
        case .ask: return nil
        case .autoEdit: return theme.accentColor
        case .plan: return Color(light: 0x23739B, dark: 0x5AAED6)
        case .fullAccess: return Palette.warning
        }
    }
}

struct WorkspaceChip: View {
    var controller: SessionController
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            if controller.session.messages.isEmpty {
                Button("Choose folder…") {
                    if let url = app.chooseFolder() { controller.setWorkspace(url) }
                }
                if !app.workspaces.isEmpty {
                    Divider()
                    ForEach(app.workspaces, id: \.path) { url in
                        Button(url.lastPathComponent) { controller.setWorkspace(url) }
                    }
                }
            } else {
                Text("This chat works in \(controller.workspaceURL?.path ?? "a scratch folder")")
                Button("Reveal in Finder") {
                    if let url = controller.workspaceURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
        } label: {
            ChipLabel(systemImage: "folder", title: controller.workspaceURL?.lastPathComponent ?? "Choose folder")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(controller.workspaceURL?.path ?? "Choose the folder Apeiron works in")
    }
}
