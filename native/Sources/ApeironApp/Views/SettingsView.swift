import ApeironKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            ProviderSettings()
                .tabItem { Label("Models", systemImage: "key.horizontal") }
            PermissionSettings()
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 620, height: 520)
        .environment(\.theme, app.settings.theme)
        .tint(app.settings.accent.color)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Model") {
                Picker("Default model", selection: $app.settings.defaultModelID) {
                    ForEach(app.allModels) { model in
                        Text("\(model.displayName) · \(model.provider.displayName)").tag(model.id)
                    }
                }
                Picker("Effort", selection: $app.settings.effort) {
                    ForEach(Effort.allCases) { effort in
                        Text(effort.label).tag(effort)
                    }
                }
                Toggle("Show the model's thinking", isOn: $app.settings.showThinking)
            }

            Section("Appearance") {
                LabeledContent("Accent") {
                    HStack(spacing: 10) {
                        ForEach(AccentChoice.allCases) { choice in
                            Button {
                                app.settings.accent = choice
                            } label: {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Palette.textPrimary.opacity(app.settings.accent == choice ? 0.8 : 0), lineWidth: 2)
                                            .padding(-3)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(choice.name)
                        }
                    }
                }
                Picker("Reading font", selection: $app.settings.readingFont) {
                    ForEach(ReadingFont.allCases) { font in
                        Text(font.label).tag(font)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Text size") {
                    HStack {
                        Image(systemName: "textformat.size.smaller")
                        Slider(value: $app.settings.textScale, in: 0.85...1.3, step: 0.05)
                            .frame(width: 180)
                        Image(systemName: "textformat.size.larger")
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Providers

private struct ProviderSettings: View {
    @Environment(AppModel.self) private var app

    private var providers: [ProviderKind] {
        ProviderKind.allCases.filter { $0 != .demo }
    }

    var body: some View {
        Form {
            Section {
                ForEach(providers) { provider in
                    ProviderKeyRow(provider: provider)
                }
            } header: {
                Text("API keys")
            } footer: {
                Text("Keys are stored in your macOS Keychain and only sent to the provider they belong to. Environment variables such as ANTHROPIC_API_KEY also work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            CustomModelSection()
        }
        .formStyle(.grouped)
    }
}

private struct ProviderKeyRow: View {
    var provider: ProviderKind
    @Environment(AppModel.self) private var app
    @State private var draft = ""
    @State private var editing = false
    @State private var baseURL = ""

    var body: some View {
        let hasKey = app.keyPresence[provider] ?? false
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(hasKey || !provider.requiresAPIKey ? Palette.success : Palette.textTertiary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(provider.displayName).fontWeight(.medium)
                Spacer()
                if let url = provider.consoleURL {
                    Link(provider.requiresAPIKey ? "Get a key" : "Download", destination: url)
                        .font(.caption)
                }
                if provider.requiresAPIKey {
                    if editing || !hasKey {
                        SecureField(provider.keyPlaceholder, text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit(save)
                        Button("Save", action: save)
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        Text("••••••••").foregroundStyle(.secondary)
                        Button("Change") { editing = true }
                        Button("Remove", role: .destructive) {
                            app.setAPIKey("", for: provider)
                        }
                    }
                }
            }
            if provider == .ollama || provider == .openRouter || provider == .openAI {
                HStack {
                    Text("Base URL").font(.caption).foregroundStyle(.secondary)
                    TextField(provider.defaultBaseURL.absoluteString, text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit(saveBaseURL)
                }
            }
        }
        .onAppear {
            baseURL = app.settings.baseURLOverrides[provider.rawValue] ?? ""
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        app.setAPIKey(key, for: provider)
        draft = ""
        editing = false
    }

    private func saveBaseURL() {
        let value = baseURL.trimmingCharacters(in: .whitespaces)
        app.settings.baseURLOverrides[provider.rawValue] = value.isEmpty ? nil : value
    }
}

/// Adds any model a provider serves, by its API id.
private struct CustomModelSection: View {
    @Environment(AppModel.self) private var app
    @State private var provider: ProviderKind = .openRouter
    @State private var apiModel = ""
    @State private var displayName = ""
    @State private var contextWindow = 128_000

    var body: some View {
        Section {
            ForEach(app.settings.customModels) { model in
                HStack {
                    VStack(alignment: .leading) {
                        Text(model.displayName)
                        Text("\(model.provider.displayName) · \(model.apiModel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        app.settings.customModels.removeAll { $0.id == model.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Picker("", selection: $provider) {
                    ForEach(ProviderKind.allCases.filter { $0 != .demo }) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                TextField("Model id, e.g. qwen/qwen3-coder", text: $apiModel)
                    .textFieldStyle(.roundedBorder)
                TextField("Name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Button("Add", action: add)
                    .disabled(apiModel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Custom models")
        }
    }

    private func add() {
        let id = apiModel.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        let name = displayName.trimmingCharacters(in: .whitespaces)
        let model = ModelDescriptor(
            provider: provider,
            apiModel: id,
            displayName: name.isEmpty ? id : name,
            tagline: "Custom",
            contextWindow: contextWindow,
            supportsVision: provider == .anthropic,
            supportsAdaptiveThinking: provider == .anthropic,
            isCustom: true
        )
        app.settings.customModels.removeAll { $0.id == model.id }
        app.settings.customModels.append(model)
        apiModel = ""
        displayName = ""
    }
}

// MARK: Permissions

private struct PermissionSettings: View {
    @Environment(AppModel.self) private var app
    @State private var newRule = ""
    @State private var newRuleIsDeny = false

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Picker("New chats start in", selection: $app.settings.defaultMode) {
                    ForEach(PermissionMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                Text(app.settings.defaultMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Mode")
            }

            Section {
                ruleList(title: "Always allow", rules: app.settings.rules.allow, isDeny: false)
                ruleList(title: "Always deny", rules: app.settings.rules.deny, isDeny: true)
                HStack {
                    TextField("bash(npm test:*) or edit_file(src/**)", text: $newRule)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(addRule)
                    Picker("", selection: $newRuleIsDeny) {
                        Text("Allow").tag(false)
                        Text("Deny").tag(true)
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    Button("Add", action: addRule)
                        .disabled(PermissionRule(parsing: newRule) == nil)
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("A rule names a tool and an optional pattern. `:*` matches a command prefix; globs match paths. Deny rules win. Catastrophic commands are always blocked, whatever the rules say.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func ruleList(title: String, rules: [PermissionRule], isDeny: Bool) -> some View {
        if !rules.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                ForEach(rules, id: \.self) { rule in
                    HStack {
                        Image(systemName: isDeny ? "xmark.circle" : "checkmark.circle")
                            .foregroundStyle(isDeny ? Palette.danger : Palette.success)
                        Text(rule.description).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button {
                            if isDeny {
                                app.settings.rules.deny.removeAll { $0 == rule }
                            } else {
                                app.settings.rules.allow.removeAll { $0 == rule }
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func addRule() {
        guard let rule = PermissionRule(parsing: newRule) else { return }
        if newRuleIsDeny {
            if !app.settings.rules.deny.contains(rule) { app.settings.rules.deny.append(rule) }
        } else {
            if !app.settings.rules.allow.contains(rule) { app.settings.rules.allow.append(rule) }
        }
        newRule = ""
    }
}

// MARK: Advanced

private struct AdvancedSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Agent loop") {
                Stepper(value: $app.settings.maxTurns, in: 10...500, step: 10) {
                    LabeledContent("Max turns per message", value: "\(app.settings.maxTurns)")
                }
                LabeledContent("Auto-compact at") {
                    HStack {
                        Slider(value: $app.settings.compactThreshold, in: 0.5...0.95, step: 0.05)
                            .frame(width: 180)
                        Text("\(Int((app.settings.compactThreshold * 100).rounded()))% of context")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent("Sessions, hooks and global memory") {
                    Button("Open ~/.apeiron") {
                        let url = ProjectContext.userConfigDirectory
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                }
                Text("Put hooks and rules in ~/.apeiron/settings.json or <project>/.apeiron/settings.json, skills in .apeiron/skills/<name>/SKILL.md, and custom slash commands in .apeiron/commands/<name>.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Files")
            }
            Section {
                Button("Reset all settings", role: .destructive) {
                    let recents = app.settings.recentWorkspaces
                    var fresh = AppSettings()
                    fresh.recentWorkspaces = recents
                    app.settings = fresh
                }
            }
        }
        .formStyle(.grouped)
    }
}
