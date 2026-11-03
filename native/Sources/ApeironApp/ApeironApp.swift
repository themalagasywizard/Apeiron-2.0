import AppKit
import ApeironKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from `swift run` there's no bundle; become a regular app
        // with a Dock icon and focus anyway.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ApeironApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup("Apeiron", id: "main") {
            RootView()
                .environment(app)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { app.newSession() }
                    .keyboardShortcut("n")
                Button("Open Folder…") { app.openFolderInNewChat() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .sidebar) {
                Button(app.showInspector ? "Hide Inspector" : "Show Inspector") {
                    app.showInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
            CommandMenu("Agent") {
                Button("Command Palette…") { app.showCommandPalette.toggle() }
                    .keyboardShortcut("k")
                Button("Switch Model…") { app.showModelPicker = true }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Button("Cycle Permission Mode") { app.currentController?.cycleMode() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Button("Stop") { app.currentController?.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!(app.currentController?.isRunning ?? false))
                Button("Retry Last Message") { app.currentController?.retryLast() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Compact Conversation") { app.currentController?.send("/compact") }
                Divider()
                Button("Export as Markdown…") { app.currentController?.exportMarkdown() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
