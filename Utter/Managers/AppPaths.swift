import Foundation
import AppKit

/// Where Utter keeps its files, plus a one-time move from the old Evertalk name
/// so the speech model (~470 MB), history and settings carry over after the rebrand.
enum AppPaths {
    static let legacyBundleID = "com.ram902.evertalk"

    static let supportDirectory: URL = {
        if DocsMode.isOn, let dir = ProcessInfo.processInfo.environment["UTTER_SUPPORT_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent("Utter", isDirectory: true)
        let legacy = base.appendingPathComponent("Evertalk", isDirectory: true)
        if !fm.fileExists(atPath: current.path) && fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: current)
        }
        return current
    }()

    /// Copies settings saved under the old app ID, once, without overwriting new ones
    static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromEvertalk"),
              let legacy = UserDefaults.standard.persistentDomain(forName: legacyBundleID) else {
            UserDefaults.standard.set(true, forKey: "migratedFromEvertalk")
            return
        }
        let keys = ["launchAtLogin", "playSounds", "showOverlayEnabled", "overlayPositionX",
                    "overlayPositionY", "historyEnabled", "historyRetentionDays",
                    "showMenuBarIcon", "appearance"]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy[key] { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "migratedFromEvertalk")
    }
}

/// Debug-only mode that renders the app's screens to PNGs for the README and guide.
/// Uses a throwaway data folder, skips the model, updates and usage counts. Always off in release builds.
enum DocsMode {
    #if DEBUG
    static let isOn = ProcessInfo.processInfo.environment["UTTER_DOCS_RENDER"] == "1"
    #else
    static let isOn = false
    #endif
    /// Pre-filled values for screenshots (debug render only)
    nonisolated(unsafe) static var searchQuery = ""
    nonisolated(unsafe) static var fixPrefill: (wrote: String, said: String) = ("", "")
}

/// Company Macs managed with Jamf need temporary admin ("Make Me Admin" in Self Service+)
/// before Accessibility can be switched on or Homebrew can write to /Applications.
enum SelfService {
    static let bundleID = "com.jamf.selfserviceplus"

    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static var isManagedMac: Bool { appURL != nil }

    static var appName: String {
        appURL.map { $0.deletingPathExtension().lastPathComponent } ?? "Self Service+"
    }

    static func open() {
        guard let url = appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
