import Foundation
import AppKit

/// Where Utter keeps its files, plus a one-time move from the old Evertalk name
/// so the speech model (~470 MB), history and settings carry over after the rebrand.
enum AppPaths {
    static let legacyBundleID = "com.ram902.evertalk"

    static let supportDirectory: URL = {
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
