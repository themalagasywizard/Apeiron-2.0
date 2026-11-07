import SwiftUI

/// A quiet, rounded button that highlights on hover.
struct GhostButtonStyle: ButtonStyle {
    var padding: EdgeInsets = EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)
    var cornerRadius: CGFloat = Metrics.cornerSmall

    func makeBody(configuration: Configuration) -> some View {
        GhostButtonBody(configuration: configuration, padding: padding, cornerRadius: cornerRadius)
    }

    private struct GhostButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let padding: EdgeInsets
        let cornerRadius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(padding)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(configuration.isPressed ? Palette.selection : (hovering ? Palette.hover : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onHover { hovering = $0 }
                .animation(Motion.fade, value: hovering)
        }
    }
}

/// Filled accent button for the primary action.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.ui(13, weight: .semibold))
            .foregroundStyle(theme.accent.onAccent)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 7)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                    .fill(theme.accentColor.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .contentShape(Rectangle())
    }
}

/// Outlined secondary button.
struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.ui(13, weight: .medium))
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 7)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                    .fill(configuration.isPressed ? Palette.selection : Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                    .strokeBorder(Palette.border)
            )
            .contentShape(Rectangle())
    }
}

/// A pill showing an icon and label, used for model/mode pickers.
struct ChipLabel: View {
    var systemImage: String?
    var title: String
    var tint: Color? = nil
    var showsChevron = true
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint ?? Palette.textSecondary)
            }
            Text(title)
                .font(theme.ui(12, weight: .medium))
                .foregroundStyle(tint ?? Palette.textSecondary)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Palette.hover))
        .contentShape(Capsule())
    }
}

/// A small rounded key cap, e.g. "⌘K".
struct KeyCap: View {
    var text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(theme.ui(10.5, weight: .medium))
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Palette.border)
            )
    }
}

/// Card chrome used by tool calls, approvals and panels.
struct CardBackground: ViewModifier {
    var highlighted: Color? = nil
    var fill: Color = Palette.surface

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                    .strokeBorder(highlighted ?? Palette.border, lineWidth: highlighted == nil ? 1 : 1.5)
            )
    }
}

extension View {
    func card(highlighted: Color? = nil, fill: Color = Palette.surface) -> some View {
        modifier(CardBackground(highlighted: highlighted, fill: fill))
    }

    /// Shows content only while the pointer is over `hovering`.
    func revealed(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0).animation(Motion.fade, value: visible)
    }
}

/// Copies text to the clipboard and briefly shows a check mark.
struct CopyButton: View {
    var text: () -> String
    var label: String? = nil
    @State private var copied = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            withAnimation(Motion.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(Motion.snappy) { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "square.on.square")
                    .font(.system(size: 11, weight: .medium))
                if let label {
                    Text(copied ? "Copied" : label).font(theme.ui(11.5))
                }
            }
            .foregroundStyle(copied ? Palette.success : Palette.textTertiary)
        }
        .buttonStyle(GhostButtonStyle(padding: EdgeInsets(top: 3, leading: 5, bottom: 3, trailing: 5)))
        .help("Copy")
    }
}

/// A circular progress ring.
struct RingGauge: View {
    var fraction: Double
    var lineWidth: CGFloat = 5
    var tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(Palette.border, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.gentle, value: fraction)
        }
    }
}

/// Three dots that pulse in sequence, for "working" states.
struct WorkingDots: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(theme.accentColor)
                        .frame(width: 4.5, height: 4.5)
                        .opacity(reduceMotion ? 0.7 : 0.3 + 0.7 * max(0, sin(time * 5 - Double(index) * 0.7)))
                }
            }
        }
    }
}

extension TimeInterval {
    var shortDuration: String {
        if self < 1 { return "\(Int(self * 1000))ms" }
        if self < 60 { return String(format: "%.1fs", self) }
        let minutes = Int(self) / 60
        let seconds = Int(self) % 60
        return "\(minutes)m \(seconds)s"
    }
}

extension Int {
    /// 1234 → "1.2k", 1_200_000 → "1.2M".
    var compactTokens: String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 10_000 { return "\(self / 1000)k" }
        if self >= 1_000 { return String(format: "%.1fk", Double(self) / 1000) }
        return "\(self)"
    }
}
