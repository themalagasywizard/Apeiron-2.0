import ApeironKit
import SwiftUI

/// Search OpenRouter's whole catalog and add models to the picker.
struct OpenRouterBrowser: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var toolsOnly = true
    @State private var freeOnly = false

    private static let quickFilters = ["Claude", "DeepSeek", "GLM", "Qwen", "Kimi", "Gemini", "GPT", "Grok", "Llama"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.border)
            content
            Divider().overlay(Palette.border)
            footer
        }
        .frame(width: 720, height: 600)
        .background(Palette.canvas)
        .task { await app.loadOpenRouterCatalog() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenRouter models")
                        .font(theme.display(22))
                        .foregroundStyle(Palette.textPrimary)
                    Text("One key, hundreds of models. Add the ones you want to the model picker.")
                        .font(theme.ui(12.5))
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                if !app.isConfigured(.openRouter) {
                    Button("Add OpenRouter key") { openSettings() }
                        .buttonStyle(AccentButtonStyle(compact: true))
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textTertiary)
                    TextField("Search by name or id, e.g. deepseek v3", text: $query)
                        .textFieldStyle(.plain)
                        .font(theme.ui(13.5))
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous).strokeBorder(Palette.border))

                Toggle("Tool use", isOn: $toolsOnly)
                    .toggleStyle(.checkbox)
                    .help("Agent work needs models that can call tools. Turn off to see chat-only models too.")
                Toggle("Free", isOn: $freeOnly)
                    .toggleStyle(.checkbox)
            }
            .font(theme.ui(12.5))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.quickFilters, id: \.self) { name in
                        let selected = query.lowercased() == name.lowercased()
                        Button {
                            query = selected ? "" : name
                        } label: {
                            Text(name)
                                .font(theme.ui(12, weight: .medium))
                                .foregroundStyle(selected ? theme.accent.onAccent : Palette.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(selected ? theme.accentColor : Palette.hover))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(18)
    }

    // MARK: List

    private var results: [OpenRouterCatalog.Entry] {
        var list = OpenRouterCatalog.search(app.openRouterEntries, query: query, toolsOnly: toolsOnly)
        if freeOnly { list = list.filter(\.isFree) }
        return list
    }

    @ViewBuilder
    private var content: some View {
        if app.openRouterLoading && app.openRouterEntries.isEmpty {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading OpenRouter's catalog…").font(theme.ui(12.5)).foregroundStyle(Palette.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = app.openRouterError, app.openRouterEntries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 22)).foregroundStyle(Palette.textTertiary)
                Text(error).font(theme.ui(12.5)).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center)
                Button("Try again") { Task { await app.loadOpenRouterCatalog(force: true) } }
                    .buttonStyle(OutlineButtonStyle(compact: true))
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let items = results
            if items.isEmpty {
                Text("No models match.")
                    .font(theme.ui(12.5))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { entry in
                            OpenRouterRow(entry: entry)
                            Divider().overlay(Palette.border).padding(.leading, 18)
                        }
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        let added = app.settings.customModels.filter { $0.provider == .openRouter }.count
        return HStack {
            Text(added == 0 ? "No models added yet" : "\(added) added to your model picker")
                .font(theme.ui(12))
                .foregroundStyle(Palette.textTertiary)
            Spacer()
            if !app.openRouterEntries.isEmpty {
                Text("\(results.count) of \(app.openRouterEntries.count) shown")
                    .font(theme.ui(12))
                    .foregroundStyle(Palette.textTertiary)
            }
            Button("Done") { dismiss() }
                .buttonStyle(AccentButtonStyle(compact: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct OpenRouterRow: View {
    var entry: OpenRouterCatalog.Entry
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let model = entry.model
        let added = app.isInModelList(model)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(theme.ui(13.5, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if entry.isFree { badge("free", tint: Palette.success) }
                    if model.supportsVision { badge("vision", tint: Palette.textTertiary) }
                    if !model.supportsTools { badge("chat only", tint: Palette.warning) }
                }
                Text(model.apiModel)
                    .font(theme.mono(11))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(theme.ui(11.5))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(model.contextWindow.compactTokens) context")
                if let input = model.inputPrice, let output = model.outputPrice, !entry.isFree {
                    Text("\(price(input)) in · \(price(output)) out")
                }
            }
            .font(theme.mono(11))
            .foregroundStyle(Palette.textTertiary)

            Button {
                withAnimation(Motion.snappy) { app.toggleModelInList(model) }
            } label: {
                Label(added ? "Added" : "Add", systemImage: added ? "checkmark" : "plus")
                    .labelStyle(.titleAndIcon)
                    .frame(width: 64)
            }
            .buttonStyle(OutlineButtonStyle(compact: true))
            .opacity(added && !hovering ? 0.7 : 1)
            .disabled(added && !app.settings.customModels.contains { $0.id == model.id })
            .help(added ? "Remove from the model picker" : "Add to the model picker")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(hovering ? Palette.hover : .clear)
        .onHover { hovering = $0 }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(theme.ui(10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().strokeBorder(tint.opacity(0.5)))
    }

    /// Per-million-token price, compact.
    private func price(_ perMillion: Double) -> String {
        perMillion >= 10 ? String(format: "$%.0f", perMillion) : String(format: "$%.2f", perMillion)
    }
}
