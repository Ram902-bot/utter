import AppKit
import ApplicationServices

class PasteManager {
    private var previousApp: NSRunningApplication?

    /// Save the frontmost app before recording starts
    func saveFrontmostApp() {
        previousApp = NSWorkspace.shared.frontmostApplication
    }

    /// Name of the app the dictation will be pasted into
    var targetAppName: String? {
        previousApp?.localizedName
    }

    /// True when inline paste can work (Accessibility granted and a target app saved)
    var canPaste: Bool {
        AXIsProcessTrusted() && previousApp != nil
    }

    /// Paste text at the cursor position in the previously active app.
    /// Returns false when the paste can't happen (text is still on the clipboard).
    @discardableResult
    func pasteText(_ text: String) -> Bool {
        let willPaste = canPaste

        // Copy to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Activate previous app and paste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.previousApp?.activate()

            // Wait for activation, then simulate Cmd+V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.simulateCmdV()
            }
        }
        return willPaste
    }

    /// Copy text to the clipboard without pasting
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func simulateCmdV() {
        guard AXIsProcessTrusted() else { return }

        let vKeyCode: CGKeyCode = 9  // 'v' key

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        usleep(100000)

        keyUp.flags = []
        keyUp.post(tap: .cghidEventTap)
    }
}
