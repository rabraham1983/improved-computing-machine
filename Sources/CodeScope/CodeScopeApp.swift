import SwiftUI
import CodeScopeCore

@main
struct CodeScopeApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var appState: AppState

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _appState = StateObject(wrappedValue: AppState(settings: settings))
    }

    var body: some Scene {
        WindowGroup("CodeScope") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(settings)
        }
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { appState.openProjectPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Close Project") { appState.closeProject() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(appState.projectURL == nil)
            }
            CommandMenu("Analysis") {
                Button("Analyze Codebase") {
                    appState.centerTab = .overview
                    appState.analyze()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.index == nil || appState.isBusy)
                Button("Re-index Project") { appState.rescan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(appState.projectURL == nil)
                Divider()
                Button("Stop Current Request") { appState.cancelCurrentTask() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!appState.isBusy)
            }
            CommandGroup(after: .toolbar) {
                Button("Overview") { appState.centerTab = .overview }.keyboardShortcut("1", modifiers: .command)
                Button("Code") { appState.centerTab = .code }.keyboardShortcut("2", modifiers: .command)
                Button("Dependency Graph") { appState.centerTab = .graph }.keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Ask") { appState.assistantTab = .ask }.keyboardShortcut("4", modifiers: .command)
                Button("Optimize") { appState.assistantTab = .optimize }.keyboardShortcut("5", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
