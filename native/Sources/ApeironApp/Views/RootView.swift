import ApeironKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var app = app
        let theme = app.settings.theme
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            } detail: {
                Group {
                    if let controller = app.currentController {
                        SessionView(controller: controller)
                            .id(controller.id)
                            .inspector(isPresented: $app.showInspector) {
                                InspectorView(controller: controller)
                                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                            }
                    } else {
                        Palette.canvas
                    }
                }
                .toolbar { toolbar }
            }
            .navigationTitle(app.currentController?.session.title ?? "Apeiron")

            if app.showCommandPalette {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { app.showCommandPalette = false }
                    .transition(.opacity)
                VStack {
                    CommandPaletteView()
                        .padding(.top, 90)
                    Spacer()
                }
                .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: app.showCommandPalette)
        .environment(\.theme, theme)
        .tint(theme.accentColor)
        .frame(minWidth: 820, minHeight: 560)
        .onChange(of: app.selection) { _, new in
            if new == nil { app.newSession() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let controller = app.currentController, let usage = controller.usage, usage.contextTokens > 0 {
                ContextToolbarGauge(usage: usage)
            }
            Button {
                app.showCommandPalette.toggle()
            } label: {
                Label("Command palette", systemImage: "command")
            }
            .help("Command palette (⌘K)")
            Button {
                withAnimation(Motion.snappy) { app.showInspector.toggle() }
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Toggle inspector (⌥⌘I)")
        }
    }
}

/// A small ring in the toolbar showing how full the context window is.
private struct ContextToolbarGauge: View {
    var usage: UsageSnapshot
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            RingGauge(fraction: usage.contextFraction, lineWidth: 2.5, tint: tint)
                .frame(width: 14, height: 14)
            Text("\(Int((usage.contextFraction * 100).rounded()))%")
                .font(theme.mono(11, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
        }
        .help("\(usage.contextTokens.compactTokens) of \(usage.contextWindow.compactTokens) tokens in context")
    }

    private var tint: Color {
        let ratio = Double(usage.contextTokens) / Double(max(1, usage.compactAt))
        if ratio > 0.9 { return Palette.danger }
        if ratio > 0.7 { return Palette.warning }
        return theme.accentColor
    }
}
