import SwiftUI
import AVFoundation
import Combine
import ApplicationServices
import ServiceManagement

@main
struct UtterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Utter", id: "main") {
            MainView(appDelegate: appDelegate)
                .environmentObject(appDelegate.appState)
                .frame(minWidth: 560, minHeight: 480)
        }
        .defaultSize(width: 860, height: 640)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") { appDelegate.appState.open(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let hotkeyManager = HotkeyManager()
    var overlayWindow: OverlayWindowController?
    /// Set by the main window; reopens it after it's been closed
    var openMainWindow: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if DocsMode.isOn {
            DocsRenderer.run(appState: appState, appDelegate: self)
            return
        }
        #endif
        AppPaths.migrateLegacyDefaults()
        syncLaunchAtLogin()
        appState.usage.appLaunched()
        appState.applyAppearance()
        appState.showMainWindowHandler = { [weak self] in self?.showMainWindow() }

        // Permissions are asked for in the setup screen (OnboardingView), not as surprise prompts

        // Connect hotkey to app state
        hotkeyManager.onHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.appState.toggleRecording()
            }
        }

        // Setup overlay window
        overlayWindow = OverlayWindowController(appState: appState)

        // Only show overlay if enabled in settings
        if appState.showOverlayEnabled {
            overlayWindow?.show()
        }

        // Listen for overlay visibility changes from Settings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOverlayVisibilityChanged(_:)),
            name: .overlayVisibilityChanged,
            object: nil
        )

        // Listen for reset position request
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleResetOverlayPosition),
            name: .resetOverlayPosition,
            object: nil
        )
    }

    /// The login item belongs to the app ID, so EverTalk's setting doesn't carry over by itself:
    /// register Utter if the user had it on, and make the toggle match what macOS actually has.
    private func syncLaunchAtLogin() {
        let service = SMAppService.mainApp
        if appState.launchAtLogin && service.status != .enabled {
            try? service.register()
        }
        appState.launchAtLogin = service.status == .enabled
    }

    /// Re-check for updates when the user comes back to Utter after a while
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await appState.updateChecker.checkIfStale() }
    }

    /// Closing the main window keeps Utter running so the hotkey still works
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon brings the main window back
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func handleOverlayVisibilityChanged(_ notification: Notification) {
        guard let enabled = notification.userInfo?["enabled"] as? Bool else { return }
        if enabled {
            overlayWindow?.show()
        } else {
            overlayWindow?.hide()
        }
    }

    @objc private func handleResetOverlayPosition() {
        overlayWindow?.resetPosition()
    }

}
