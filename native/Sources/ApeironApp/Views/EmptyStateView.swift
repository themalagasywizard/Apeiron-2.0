import ApeironKit
import SwiftUI

/// The first screen of a new chat: a greeting, the composer front and centre,
/// and a few starting points tailored to whether a folder is open.
private struct Suggestion: Identifiable {
    var icon: String
    var title: String
    var prompt: String
    var id: String { title }
}

struct EmptyStateView: View {
    var controller: SessionController
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 40)
            VStack(spacing: 14) {
                ApeironMark(size: 40, isActive: false)
                Text(greeting)
                    .font(theme.display(34))
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)

            VStack(spacing: 12) {
                if let banner = controller.errorBanner {
                    ErrorBanner(message: banner, controller: controller)
                }
                if !app.hasAnyKey && controller.model.provider.requiresAPIKey {
                    onboardingCard
                }
                ComposerView(controller: controller)
                suggestions
            }
            .frame(maxWidth: 680)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)

            Spacer(minLength: 60)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(Motion.gentle.delay(0.05)) { appeared = true }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part: String
        switch hour {
        case 5..<12: part = "Good morning"
        case 12..<17: part = "Good afternoon"
        case 17..<22: part = "Good evening"
        default: part = "Burning the midnight oil"
        }
        if let name = app.userFirstName, !name.isEmpty { return "\(part), \(name)" }
        return part
    }

    private var onboardingCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(theme.accentColor)
                .frame(width: 36, height: 36)
                .background(Circle().fill(theme.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect a model to get started")
                    .font(theme.ui(13.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Add an Anthropic key (or any provider) in Settings, or try the offline demo.")
                    .font(theme.ui(12.5))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Button("Try demo") {
                if let demo = app.allModels.first(where: { $0.provider == .demo }) {
                    controller.setModel(demo)
                }
            }
            .buttonStyle(OutlineButtonStyle(compact: true))
            Button("Add key") { openSettings() }
                .buttonStyle(AccentButtonStyle(compact: true))
        }
        .padding(14)
        .card(fill: Palette.surfaceRaised)
    }

    private var suggestions: some View {
        let items: [Suggestion] = controller.workspaceURL == nil
            ? [
                Suggestion(icon: "folder.badge.plus", title: "Open a project", prompt: "__open__"),
                Suggestion(icon: "lightbulb", title: "Explain a concept", prompt: "Explain how async/await works in Swift, with a small example."),
                Suggestion(icon: "doc.text", title: "Draft something", prompt: "Help me write a clear README for a new open-source tool."),
            ]
            : [
                Suggestion(icon: "map", title: "Explain this codebase", prompt: "Give me a tour of this codebase: what it does, how it's organised, and where to start reading."),
                Suggestion(icon: "ladybug", title: "Find and fix a bug", prompt: "Look for likely bugs in this project, then fix the most important one and explain the change."),
                Suggestion(icon: "checkmark.seal", title: "Add tests", prompt: "Find code in this project that lacks tests and add focused tests for it. Run them."),
                Suggestion(icon: "text.badge.star", title: "Write APEIRON.md", prompt: "/init"),
            ]
        return HStack(spacing: 8) {
            ForEach(items) { item in
                let icon = item.icon
                let title = item.title
                let prompt = item.prompt
                Button {
                    if prompt == "__open__" {
                        if let url = app.chooseFolder() { controller.setWorkspace(url) }
                    } else {
                        controller.send(prompt)
                    }
                } label: {
                    Label(title, systemImage: icon)
                        .font(theme.ui(12.5, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().strokeBorder(Palette.border))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
