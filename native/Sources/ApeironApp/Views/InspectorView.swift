import ApeironKit
import SwiftUI

/// The right-hand panel: the agent's task list, context usage and the files
/// it changed this session.
struct InspectorView: View {
    var controller: SessionController
    @Environment(\.theme) private var theme
    @State private var tab: Tab = .tasks
    @State private var selectedFile: String?

    enum Tab: String, CaseIterable, Identifiable {
        case tasks = "Tasks"
        case context = "Context"
        case changes = "Changes"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(title(for: tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider().overlay(Palette.border)

            ScrollView {
                Group {
                    switch tab {
                    case .tasks: tasks
                    case .context: context
                    case .changes: changes
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Palette.sidebar)
        .onChange(of: controller.todos.count) { old, new in
            if old == 0 && new > 0 { tab = .tasks }
        }
    }

    private func title(for tab: Tab) -> String {
        switch tab {
        case .tasks:
            let open = controller.todos.filter { $0.status != .completed }.count
            return open > 0 ? "Tasks \(open)" : "Tasks"
        case .changes:
            return controller.changedFiles.isEmpty ? "Changes" : "Changes \(controller.changedFiles.count)"
        case .context:
            return "Context"
        }
    }

    // MARK: Tasks

    @ViewBuilder
    private var tasks: some View {
        if controller.todos.isEmpty {
            placeholder(icon: "checklist", title: "No tasks yet", detail: "For multi-step work, Apeiron keeps a live task list here.")
        } else {
            let done = controller.todos.filter { $0.status == .completed }.count
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("\(done) of \(controller.todos.count) done")
                        .font(theme.ui(12, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                }
                ProgressView(value: Double(done), total: Double(max(1, controller.todos.count)))
                    .tint(theme.accentColor)
                TodoListView(items: controller.todos)
            }
        }
    }

    // MARK: Context

    @ViewBuilder
    private var context: some View {
        let usage = controller.usage
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                ZStack {
                    RingGauge(fraction: usage?.contextFraction ?? 0, lineWidth: 7, tint: gaugeTint(usage))
                    VStack(spacing: 0) {
                        Text("\(Int(((usage?.contextFraction ?? 0) * 100).rounded()))%")
                            .font(theme.ui(17, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                        Text("used").font(theme.ui(10.5)).foregroundStyle(Palette.textTertiary)
                    }
                }
                .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\((usage?.contextTokens ?? 0).compactTokens) of \((usage?.contextWindow ?? controller.model.contextWindow).compactTokens) tokens")
                        .font(theme.ui(13, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                    Text("Auto-compacts at \((usage?.compactAt ?? 0).compactTokens)")
                        .font(theme.ui(11.5))
                        .foregroundStyle(Palette.textTertiary)
                    Button("Compact now") { controller.send("/compact") }
                        .buttonStyle(OutlineButtonStyle(compact: true))
                        .disabled(controller.isRunning || controller.session.messages.isEmpty)
                        .padding(.top, 4)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("This session").font(theme.ui(11, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                let total = usage?.total ?? controller.session.usage
                statRow("Input", total.inputTokens.compactTokens)
                statRow("Cached reads", total.cacheReadTokens.compactTokens)
                statRow("Cache writes", total.cacheWriteTokens.compactTokens)
                statRow("Output", total.outputTokens.compactTokens)
                if let cost = usage?.estimatedCost ?? controller.model.cost(of: total) {
                    Divider().overlay(Palette.border)
                    statRow("Estimated cost", String(format: "$%.3f", cost))
                }
                if total.promptTokens > 0 {
                    let hitRate = Double(total.cacheReadTokens) / Double(total.promptTokens)
                    statRow("Cache hit rate", "\(Int((hitRate * 100).rounded()))%")
                }
            }
            .padding(12)
            .card()

            VStack(alignment: .leading, spacing: 6) {
                Text("Model").font(theme.ui(11, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                Text(controller.model.displayName).font(theme.ui(13, weight: .medium)).foregroundStyle(Palette.textPrimary)
                Text(controller.model.apiModel).font(theme.mono(11.5)).foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private func gaugeTint(_ usage: UsageSnapshot?) -> Color {
        guard let usage else { return theme.accentColor }
        let ratio = Double(usage.contextTokens) / Double(max(1, usage.compactAt))
        if ratio > 0.9 { return Palette.danger }
        if ratio > 0.7 { return Palette.warning }
        return theme.accentColor
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(theme.ui(12.5)).foregroundStyle(Palette.textSecondary)
            Spacer()
            Text(value).font(theme.mono(12, weight: .medium)).foregroundStyle(Palette.textPrimary)
        }
    }

    // MARK: Changes

    @ViewBuilder
    private var changes: some View {
        if controller.changedFiles.isEmpty {
            placeholder(icon: "doc.on.doc", title: "No changes yet", detail: "Files Apeiron creates or edits in this session show up here with their diffs.")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(controller.changedFiles) { file in
                    let stats = file.stats
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation(Motion.snappy) {
                                selectedFile = selectedFile == file.path ? nil : file.path
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: file.original.isEmpty ? "doc.badge.plus" : "doc.text")
                                    .foregroundStyle(Palette.textTertiary)
                                Text(file.path)
                                    .font(theme.ui(12.5, weight: .medium))
                                    .foregroundStyle(Palette.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer()
                                Text("+\(stats.added)").foregroundStyle(Palette.success)
                                Text("−\(stats.removed)").foregroundStyle(Palette.danger)
                            }
                            .font(theme.mono(11.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if selectedFile == file.path {
                            DiffView(path: file.path, before: file.original, after: file.latest, maxHeight: 420)
                        }
                    }
                }
            }
        }
    }

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            Text(title).font(theme.ui(13, weight: .medium)).foregroundStyle(Palette.textSecondary)
            Text(detail)
                .font(theme.ui(12))
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}
