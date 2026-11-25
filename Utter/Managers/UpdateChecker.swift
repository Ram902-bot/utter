import AppKit
import Foundation
import UserNotifications

/// Checks the Homebrew tap for a newer Utter and upgrades through Homebrew.
/// Reads the cask file rather than the GitHub releases API: the API allows 60
/// unauthenticated requests per hour per IP, which a shared office egress IP exhausts.
@MainActor
class UpdateChecker: ObservableObject {
    enum UpdateState: Equatable {
        case idle
        case available(String)
        case updating
        case failed(String)
    }

    @Published var state: UpdateState = .idle

    /// New cask first; the old "evertalk" cask covers the move from Evertalk
    private static let caskURLs = [
        URL(string: "https://raw.githubusercontent.com/Ram902-bot/homebrew-tap/main/Casks/utter.rb")!,
        URL(string: "https://raw.githubusercontent.com/Ram902-bot/homebrew-tap/main/Casks/evertalk.rb")!
    ]
    private static let releasesURL = URL(string: "https://github.com/Ram902-bot/utter/releases/latest")!
    nonisolated private static let tapCask = "ram902-bot/tap/utter"
    nonisolated private static let tapName = "ram902-bot/tap"
    private static let notifiedKey = "updateNotifiedVersion"
    private static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    private static let checkInterval: TimeInterval = 6 * 60 * 60

    private var timer: Timer?
    private var lastCheck: Date?
    /// Banner on the History page hidden until the next launch
    @Published var bannerDismissed = false

    /// Release notes for a version
    func notesURL(for version: String) -> URL {
        URL(string: "https://github.com/Ram902-bot/utter/releases/tag/v\(version)")!
    }

    /// Checks again if the last check was over an hour ago
    func checkIfStale() async {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 3600 { return }
        await checkForUpdates()
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    init() {
        if DocsMode.isOn { return }
        Task { await checkForUpdates() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForUpdates()
            }
        }
    }

    func checkForUpdates() async {
        guard state != .updating else { return }
        lastCheck = Date()
        for url in Self.caskURLs {
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                request.setValue("Utter/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let cask = String(data: data, encoding: .utf8),
                      let latest = Self.parseVersion(fromCask: cask) else { continue }

                if Self.isVersion(latest, newerThan: currentVersion) {
                    print("Update available: \(currentVersion) -> \(latest)")
                    state = .available(latest)
                    notifyOnce(about: latest)
                } else if case .available = state {
                    state = .idle
                }
                return
            } catch {
                // Offline or blocked: stay quiet and try again on the next check
                print("Update check failed: \(error.localizedDescription)")
                return
            }
        }
    }

    /// Upgrade via Homebrew, then relaunch. Without Homebrew, open the releases page.
    func installUpdate() {
        guard let brew = Self.brewPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            NSWorkspace.shared.open(Self.releasesURL)
            return
        }

        state = .updating
        Task.detached {
            let result = Self.run(brew, ["update", "--quiet"])
            let upgrade: (status: Int32, output: String)
            if result.status != 0 {
                upgrade = result
            } else {
                let installed = Self.run(brew, ["list", "--cask"]).output.split(separator: "\n").map(String.init)
                if installed.contains("utter") {
                    upgrade = Self.run(brew, ["upgrade", "--cask", "utter"])
                } else if installed.contains("evertalk") {
                    // Came from Evertalk: the evertalk cask installs Utter and is kept in sync on every
                    // release, so upgrade it in place. Never uninstall first: if the install then failed
                    // (e.g. the tap isn't trusted) the user would be left with no app.
                    upgrade = Self.run(brew, ["upgrade", "--cask", "evertalk"])
                } else {
                    // Newer Homebrew refuses casks from taps that aren't trusted
                    _ = Self.run(brew, ["trust", "--tap", Self.tapName])
                    upgrade = Self.run(brew, ["install", "--cask", Self.tapCask])
                }
            }
            await MainActor.run {
                if upgrade.status == 0 {
                    Self.relaunch()
                } else {
                    let lastLine = upgrade.output.split(separator: "\n").last.map(String.init) ?? "Homebrew exited with \(upgrade.status)"
                    self.state = .failed(lastLine)
                }
            }
        }
    }

    // MARK: - Notification

    /// One macOS notification per new version, so people notice without opening the app
    private func notifyOnce(about version: String) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.notifiedKey) != version else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Utter \(version) is available"
            content.body = "Open Utter and click Update. It takes about a minute."
            center.add(UNNotificationRequest(identifier: "utter-update-\(version)", content: content, trigger: nil))
            DispatchQueue.main.async { defaults.set(version, forKey: Self.notifiedKey) }
        }
    }

    // MARK: - Helpers

    nonisolated private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Apps launched from Finder get a minimal PATH; Homebrew needs its own bin dirs
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func relaunch() {
        let appPath = Bundle.main.bundlePath
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit before reopening the upgraded app
        relauncher.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.5; done; open \"\(appPath)\""]
        try? relauncher.run()
        NSApplication.shared.terminate(nil)
    }

    static func parseVersion(fromCask cask: String) -> String? {
        for line in cask.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("version ") else { continue }
            let parts = trimmed.split(separator: "\"")
            if parts.count >= 2 { return String(parts[1]) }
        }
        return nil
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
