import ApeironKit
import SwiftUI

struct UserMessageView: View {
    var item: UserItem
    var onEdit: ((String) -> Void)?
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 6) {
                if !item.attachmentNames.isEmpty || item.imageCount > 0 {
                    HStack(spacing: 6) {
                        ForEach(item.attachmentNames, id: \.self) { name in
                            Label(name, systemImage: "paperclip")
                                .font(theme.ui(11.5))
                                .foregroundStyle(Palette.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Palette.hover))
                        }
                    }
                }
                Text(item.text)
                    .font(theme.body())
                    .foregroundStyle(Palette.textPrimary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                            .fill(Palette.userBubble)
                    )
                HStack(spacing: 2) {
                    if let onEdit {
                        Button { onEdit(item.text) } label: {
                            Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .buttonStyle(GhostButtonStyle(padding: EdgeInsets(top: 3, leading: 5, bottom: 3, trailing: 5)))
                        .help("Edit and resend")
                    }
                    CopyButton(text: { item.text })
                }
                .revealed(hovering)
            }
        }
        .onHover { hovering = $0 }
    }
}

struct AssistantTextView: View {
    var model: AssistantTextModel
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownView(text: model.text, isStreaming: model.isStreaming)
            if !model.isStreaming {
                HStack(spacing: 2) {
                    CopyButton(text: { model.text })
                }
                .revealed(hovering)
            }
        }
        .onHover { hovering = $0 }
    }
}

struct ThinkingView: View {
    var model: ThinkingModel
    @State private var expanded = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .medium))
                    Text(label)
                        .font(theme.ui(12.5, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    if model.isStreaming { WorkingDots() }
                }
                .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(GhostButtonStyle(padding: EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6)))
            .padding(.leading, -6)

            if expanded || model.isStreaming {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 1).fill(Palette.border).frame(width: 2)
                    Text(expanded ? model.text : String(model.text.suffix(280)))
                        .font(theme.body(13.5))
                        .foregroundStyle(Palette.textSecondary)
                        .lineSpacing(3)
                        .lineLimit(expanded ? nil : 3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var label: String {
        if model.isStreaming { return "Thinking" }
        if let duration = model.duration, duration >= 1 { return "Thought for \(duration.shortDuration)" }
        return "Thoughts"
    }
}

struct NoticeView: View {
    var item: NoticeItem
    @Environment(\.theme) private var theme

    var body: some View {
        switch item.style {
        case .help:
            MarkdownView(text: item.text)
                .padding(16)
                .card(fill: Palette.surfaceSunken)
        case .compaction:
            HStack(spacing: 10) {
                line
                Label(item.text, systemImage: "rectangle.compress.vertical")
                    .font(theme.ui(12))
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                line
            }
        default:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .font(.system(size: 12, weight: .semibold))
                Text(item.text)
                    .font(theme.ui(13))
                    .foregroundStyle(item.style == .error ? Palette.danger : Palette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                    .fill(tint.opacity(item.style == .info ? 0.06 : 0.1))
            )
        }
    }

    private var line: some View {
        Rectangle().fill(Palette.border).frame(height: 1)
    }

    private var symbol: String {
        switch item.style {
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        default: return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch item.style {
        case .warning: return Palette.warning
        case .error: return Palette.danger
        default: return Palette.textTertiary
        }
    }
}

// MARK: - Tool cards

struct ToolCardView: View {
    var model: ToolCardModel
    @State private var expanded = false
    @State private var hovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.snappy) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded {
                Divider().overlay(Palette.border)
                detail
                    .transition(.opacity)
            }
        }
        .card(highlighted: model.status == .awaitingApproval ? theme.accentColor : nil)
        .animation(Motion.snappy, value: model.status)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(iconBackground)
                    .frame(width: 24, height: 24)
                Image(systemName: model.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(iconForeground)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(theme.ui(13, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = model.detail, detail != model.title {
                    Text(detail)
                        .font(theme.mono(11.5))
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if let stats = diffStats {
                HStack(spacing: 4) {
                    Text("+\(stats.added)").foregroundStyle(Palette.success)
                    Text("−\(stats.removed)").foregroundStyle(Palette.danger)
                }
                .font(theme.mono(11.5, weight: .medium))
            }
            statusView
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.textTertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .opacity(hovering || expanded ? 1 : 0.4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.status {
        case .preparing:
            Text("writing…").font(theme.ui(11.5)).foregroundStyle(Palette.textTertiary)
        case .awaitingApproval:
            Text("needs approval").font(theme.ui(11.5, weight: .medium)).foregroundStyle(theme.accentColor)
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
        case .succeeded:
            if let duration = model.duration, duration >= 0.5 {
                Text(duration.shortDuration).font(theme.ui(11.5)).foregroundStyle(Palette.textTertiary)
            }
            Image(systemName: "checkmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Palette.success)
        case .failed:
            Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.danger)
        case .denied:
            Text("declined").font(theme.ui(11.5)).foregroundStyle(Palette.textTertiary)
        }
    }

    private var iconBackground: Color {
        switch model.status {
        case .failed: return Palette.danger.opacity(0.12)
        case .awaitingApproval: return theme.accentColor.opacity(0.15)
        default: return Palette.hover
        }
    }

    private var iconForeground: Color {
        switch model.status {
        case .failed: return Palette.danger
        case .awaitingApproval, .running: return theme.accentColor
        default: return Palette.textSecondary
        }
    }

    private var diffStats: (added: Int, removed: Int)? {
        if case .diff(_, let before, let after)? = model.metadata {
            return LineDiff.stats(before: before, after: after)
        }
        return nil
    }

    @ViewBuilder
    private var detail: some View {
        switch model.metadata {
        case .diff(let path, let before, let after)?:
            DiffView(path: path, before: before, after: after)
                .padding(10)
        case .todos(let items)?:
            TodoListView(items: items)
                .padding(12)
        default:
            VStack(alignment: .leading, spacing: 8) {
                if model.name == "bash", let command = model.input["command"]?.stringValue {
                    Text("$ " + command)
                        .font(theme.mono(12, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .textSelection(.enabled)
                } else if model.name != "todo_write", model.input.objectValue?.isEmpty == false {
                    Text(model.input.serialized(pretty: true))
                        .font(theme.mono(11.5))
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
                if let output = model.output {
                    ScrollView {
                        Text(output.isEmpty ? "(no output)" : String(output.prefix(20_000)))
                            .font(theme.mono(12))
                            .foregroundStyle(model.status == .failed ? Palette.danger : Palette.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.code.opacity(0.6))
        }
    }
}

struct TodoListView: View {
    var items: [TodoItem]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: symbol(item.status))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(color(item.status))
                    Text(item.status == .inProgress ? (item.activeForm ?? item.content) : item.content)
                        .font(theme.ui(13, weight: item.status == .inProgress ? .semibold : .regular))
                        .foregroundStyle(item.status == .completed ? Palette.textTertiary : Palette.textPrimary)
                        .strikethrough(item.status == .completed, color: Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func symbol(_ status: TodoItem.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted.circle"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func color(_ status: TodoItem.Status) -> Color {
        switch status {
        case .pending: return Palette.textTertiary
        case .inProgress: return theme.accentColor
        case .completed: return Palette.success
        }
    }
}

struct DiffView: View {
    var path: String
    var before: String
    var after: String
    var maxHeight: CGFloat = 360
    @Environment(\.theme) private var theme

    var body: some View {
        let hunks = LineDiff.hunks(before: before, after: after)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: before.isEmpty ? "doc.badge.plus" : "doc.text")
                Text(path).lineLimit(1).truncationMode(.middle)
                Spacer()
                CopyButton(text: { LineDiff.unified(path: path, before: before, after: after) }, label: "Copy diff")
            }
            .font(theme.ui(12, weight: .medium))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider().overlay(Palette.border)
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(hunks.enumerated()), id: \.offset) { index, hunk in
                        if index > 0 {
                            Text("⋯").font(theme.mono(11)).foregroundStyle(Palette.textTertiary).padding(.vertical, 2).padding(.leading, 12)
                        }
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            DiffLineView(line: line)
                        }
                    }
                    if hunks.isEmpty {
                        Text("No changes").font(theme.ui(12)).foregroundStyle(Palette.textTertiary).padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: maxHeight)
        }
        .card(fill: Palette.code)
    }
}

private struct DiffLineView: View {
    var line: LineDiff.Line
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 36, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 36, alignment: .trailing)
            Text(marker)
                .frame(width: 20)
                .foregroundStyle(markerColor)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize()
                .padding(.trailing, 12)
        }
        .font(theme.mono(12))
        .foregroundStyle(Palette.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return ""
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .added: return Palette.success
        case .removed: return Palette.danger
        case .context: return Palette.textTertiary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: return Palette.diffAdded
        case .removed: return Palette.diffRemoved
        case .context: return .clear
        }
    }
}
