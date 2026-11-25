#if DEBUG
import SwiftUI

/// Debug-only: renders Utter's screens to PNGs for the README and the enablement guide.
/// Run with UTTER_DOCS_RENDER=1, UTTER_SUPPORT_DIR=<folder with dummy data>, UTTER_DOCS_OUT=<output folder>.
@MainActor
enum DocsRenderer {
    static func run(appState: AppState, appDelegate: AppDelegate) {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: env["UTTER_DOCS_OUT"] ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let wasOnboarded = appState.onboardingComplete
        NSApp.appearance = NSAppearance(named: env["UTTER_DOCS_DARK"] == "1" ? .darkAqua : .aqua)
        NSApp.windows.forEach { $0.orderOut(nil) }

        Task { @MainActor in
            let windowSize = CGSize(width: 980, height: 640)
            func main(_ page: AppPage) -> some View {
                MainView(appDelegate: appDelegate).environmentObject(appState)
            }

            appState.onboardingComplete = true

            appState.selectedPage = .history
            await snap(main(.history), size: windowSize, name: "history", out: out)

            appState.updateChecker.state = .available("3.1.0")
            await snap(main(.history), size: windowSize, name: "history-update", out: out)
            appState.updateChecker.state = .idle

            DocsMode.searchQuery = "PrimeLogic"
            appState.selectedPage = .history
            await snap(main(.history), size: windowSize, name: "history-search", out: out)
            DocsMode.searchQuery = ""

            appState.selectedPage = .vocabulary
            await snap(main(.vocabulary), size: windowSize, name: "vocabulary", out: out)

            appState.selectedPage = .setup
            await snap(main(.setup), size: CGSize(width: 980, height: 760), name: "setup", out: out)

            appState.selectedPage = .settings
            await snap(main(.settings), size: CGSize(width: 980, height: 900), name: "settings", out: out)

            if let entry = appState.history.entries.first(where: { $0.text.contains("Wibecraft") }) {
                DocsMode.fixPrefill = ("Wibecraft", "VibeCraft")
                await snap(FixWordSheet(entry: entry).environmentObject(appState),
                           size: CGSize(width: 460, height: 500), name: "fix-word", out: out, titled: false)
                DocsMode.fixPrefill = ("", "")
            }

            let review = VocabularyView.ImportReview(
                fileLabel: "team-glossary.md",
                terms: ["Everstage", "PrimeLogic", "VibeCraft", "Eva", "Relay", "ICM", "SPIFF", "RevOps",
                        "Commission Plan", "Datasheet", "Northwind", "Payout", "Quota", "Why Now"],
                unreadable: 0)
            await snap(ImportReviewSheet(review: review, onAdd: { _ in }),
                       size: CGSize(width: 520, height: 420), name: "import-review", out: out, titled: false)


            // Recording indicator states, on a dark backdrop like the desktop
            func pill() -> some View {
                OverlayView().environmentObject(appState)
                    .environment(\.colorScheme, .dark)
                    .padding(20)
                    .background(Color(white: 0.18))
            }
            let pillSize = CGSize(width: 280, height: 74)
            appState.status = .idle
            appState.lastResult = nil
            await snap(pill(), size: pillSize, name: "pill-idle", out: out, titled: false)
            appState.status = .recording
            appState.recordingStartedAt = Date().addingTimeInterval(-7)
            appState.levels = [0.2, 0.5, 0.8, 0.6, 0.9, 0.4, 0.7, 0.5, 0.3]
            await snap(pill(), size: pillSize, name: "pill-recording", out: out, titled: false)
            appState.status = .transcribing
            await snap(pill(), size: pillSize, name: "pill-transcribing", out: out, titled: false)
            appState.status = .idle
            appState.lastResult = .pasted
            await snap(pill(), size: pillSize, name: "pill-pasted", out: out, titled: false)
            appState.lastResult = .copiedOnly
            await snap(pill(), size: pillSize, name: "pill-copied", out: out, titled: false)

            appState.onboardingComplete = wasOnboarded
            NSApp.terminate(nil)
        }
    }

    /// Lays a view out in an off-screen window and saves the whole window (title bar included) as PNG
    static func snap<V: View>(_ view: V, size: CGSize, name: String, out: URL, titled: Bool = true) async {
        // Always a real titled window so it can become key (default buttons draw blue, not faded);
        // untitled shots capture only the content
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Utter"
        if !titled {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        let host = NSHostingView(rootView: view)
        window.contentView = host
        // On screen: macOS only draws translucent sidebars and highlighted buttons in visible windows
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let target: NSView = titled ? (host.superview ?? host) : host
        target.layoutSubtreeIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: out.appendingPathComponent("\(name).png"))
        }
        window.orderOut(nil)
    }
}
#endif
