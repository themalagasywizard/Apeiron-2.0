import ApeironKit
import SwiftUI

/// The approval sheet that slides up above the composer when a tool needs
/// permission. Return allows once, ⌘Return always allows, Esc declines.
struct ApprovalView: View {
    var approval: PendingApproval
    var queued: Int
    var onReply: (PermissionReply) -> Void
    @State private var feedback = ""
    @State private var showFeedback = false
    @FocusState private var feedbackFocused: Bool
    @Environment(\.theme) private var theme

    private var request: PermissionRequest { approval.request }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(theme.ui(14, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    if let reason = request.reason {
                        Text(reason)
                            .font(theme.ui(12))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                Spacer()
                if queued > 0 {
                    Text("+\(queued) more")
                        .font(theme.ui(11.5, weight: .medium))
                        .foregroundStyle(Palette.textTertiary)
                }
            }

            preview

            if showFeedback {
                TextField("Tell Apeiron what to do instead (optional)", text: $feedback, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(theme.ui(13))
                    .lineLimit(1...4)
                    .padding(10)
                    .card(fill: Palette.surfaceSunken)
                    .focused($feedbackFocused)
                    .onSubmit { onReply(.deny(feedback: feedback)) }
            }

            HStack(spacing: 8) {
                Button {
                    if showFeedback {
                        onReply(.deny(feedback: feedback.isEmpty ? nil : feedback))
                    } else {
                        withAnimation(Motion.snappy) { showFeedback = true }
                        feedbackFocused = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(showFeedback ? "Send & decline" : "Decline")
                        KeyCap(text: "esc")
                    }
                }
                .buttonStyle(OutlineButtonStyle(compact: true))
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    onReply(.allowAlways(request.suggestedRule))
                } label: {
                    HStack(spacing: 6) {
                        Text("Always allow")
                        Text(request.suggestedRule.description)
                            .font(theme.mono(11))
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180)
                        KeyCap(text: "⌘↩")
                    }
                }
                .buttonStyle(OutlineButtonStyle(compact: true))
                .keyboardShortcut(.return, modifiers: .command)

                Button {
                    onReply(.allowOnce)
                } label: {
                    HStack(spacing: 6) {
                        Text("Allow")
                        KeyCap(text: "↩").colorInvert().opacity(0.8)
                    }
                }
                .buttonStyle(AccentButtonStyle(compact: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                .fill(Palette.surfaceRaised)
                .shadow(color: Palette.shadow, radius: 18, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                .strokeBorder(theme.accentColor.opacity(0.55), lineWidth: 1.2)
        )
    }

    @ViewBuilder
    private var preview: some View {
        switch request.preview {
        case .command(let command)?:
            ScrollView(.horizontal, showsIndicators: false) {
                Text("$ " + command)
                    .font(theme.mono(12.5, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(fill: Palette.code)
        case .diff(let path, let before, let after)?:
            DiffView(path: path, before: before, after: after, maxHeight: 240)
        case .text(let text)?:
            Text(text)
                .font(theme.mono(12))
                .foregroundStyle(Palette.textSecondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(fill: Palette.code)
        case nil:
            if let subject = request.subject {
                Text(subject)
                    .font(theme.mono(12))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(3)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(fill: Palette.code)
            }
        }
    }

    private var headline: String {
        switch request.category {
        case .execute: return "Run this command?"
        case .write: return request.toolName == "write_file" ? "Write this file?" : "Make this edit?"
        case .network: return "Fetch from the web?"
        case .read: return "Read outside the project?"
        case .meta: return "Allow \(request.title)?"
        }
    }

    private var icon: String {
        switch request.category {
        case .execute: return "terminal"
        case .write: return "pencil.line"
        case .network: return "globe"
        case .read: return "eye"
        case .meta: return "sparkles"
        }
    }
}
