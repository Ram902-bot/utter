import SwiftUI
import Carbon
import Combine

class HotkeyManager: ObservableObject {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    // Callback to trigger when hotkey is pressed
    var onHotkeyPressed: (() -> Void)?

    /// False while another app (e.g. the old EverTalk) holds Cmd+Shift+Space; retried until free
    private(set) var isRegistered = false
    private var retryTimer: Timer?

    init() {
        registerHotkey()
    }

    deinit {
        unregisterHotkey()
    }

    private func registerHotkey() {
        // Cmd+Shift+Space
        // Modifiers: cmdKey (256) + shiftKey (512) = 768
        // Key code for Space: 49

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4556544B) // "EVTK" in hex
        hotKeyID.id = 1

        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)

        // Install event handler
        let handlerBlock: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

            DispatchQueue.main.async {
                manager.onHotkeyPressed?()
            }

            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handlerBlock,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        // Register the hotkey
        // cmdKey = 256, shiftKey = 512, so cmdKey + shiftKey = 768
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let keyCode: UInt32 = 49 // Space

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        isRegistered = status == noErr
        if !isRegistered { scheduleRetry() }
    }

    /// Keep trying every few seconds, so the shortcut starts working as soon as the other app lets go
    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            var hotKeyID = EventHotKeyID()
            hotKeyID.signature = OSType(0x4556544B)
            hotKeyID.id = 1
            let status = RegisterEventHotKey(49, UInt32(cmdKey | shiftKey), hotKeyID,
                                             GetApplicationEventTarget(), 0, &self.hotKeyRef)
            if status == noErr {
                self.isRegistered = true
                timer.invalidate()
                self.retryTimer = nil
            }
        }
    }

    private func unregisterHotkey() {
        retryTimer?.invalidate()
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
}
