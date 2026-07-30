import SwiftUI

@main
struct PortsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var themeStore = ThemeStore.shared

    var body: some Scene {
        Window("Portside", id: "main") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(themeStore)
                .environment(\.appTheme, themeStore.theme)
                .tint(themeStore.theme.primary)
                .frame(minWidth: 1000, minHeight: 640)
                .task {
                    appState.start()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await appState.updates.check(userInitiated: true) }
                }
                Link("Buy Me a Coffee…", destination: BuyMeACoffee.url)
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette…") {
                    appState.showCommandPalette.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("Refresh") {
                    Task { await appState.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            SidebarCommands()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeStore.shared.applyAppearance()
        MenuBarController.shared.setup()
    }

    /// Closing the last window must NOT quit the app while the menu bar
    /// companion is on — Portside keeps monitoring (and notifying) in the
    /// background; the window comes back via Dock click or "Open Portside".
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        ConfigStore.shared.config.trayEnabled == false
    }

    /// Dock icon clicked with no visible windows: reopen the main window.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Portside" }?
                .makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        HistoryStore.shared.flush()
    }
}
