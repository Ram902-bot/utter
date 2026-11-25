import Foundation

/// Anonymous usage counts, so we know whether people install and actually use Utter.
/// Sends only: a random install ID, the event name, Utter version and macOS version.
/// Never dictated text, history, vocabulary, app names or anything about the person.
/// Users can switch it off in Settings; nothing is sent when it's off.
@MainActor
final class UsageReporter {
    enum Event: String {
        case installed          // first launch of Utter
        case firstDictation = "first_dictation"
        case activeWeek = "active_week"   // at most once per week, only if they dictated
    }

    static let enabledKey = "shareUsageCounts"
    private static let idKey = "usageInstallID"
    private static let sentInstalledKey = "usageSentInstalled"
    private static let sentFirstKey = "usageSentFirstDictation"
    private static let lastWeekKey = "usageLastActiveWeek"
    private static let pendingKey = "usagePending"

    /// Receiver address, set in Info.plist as UtterUsageEndpoint (the Google Apps Script web app URL).
    /// Empty = reporting is off for this build.
    private let endpoint: URL? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "UtterUsageEndpoint") as? String,
              value.hasPrefix("https://") else { return nil }
        return URL(string: value)
    }()

    private let defaults = UserDefaults.standard
    private var flushing = false

    var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled { defaults.removeObject(forKey: Self.pendingKey) }
    }

    private var installID: String {
        if let id = defaults.string(forKey: Self.idKey) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Self.idKey)
        return id
    }

    /// Call on every launch
    func appLaunched() {
        if !defaults.bool(forKey: Self.sentInstalledKey), enqueue(.installed) {
            defaults.set(true, forKey: Self.sentInstalledKey)
        }
        flush()
    }

    /// Call after each finished dictation
    func dictationCompleted() {
        if !defaults.bool(forKey: Self.sentFirstKey), enqueue(.firstDictation) {
            defaults.set(true, forKey: Self.sentFirstKey)
        }
        let week = Self.currentWeek()
        if defaults.string(forKey: Self.lastWeekKey) != week, enqueue(.activeWeek) {
            defaults.set(week, forKey: Self.lastWeekKey)
        }
        flush()
    }

    // MARK: - Sending

    /// Returns false when reporting is off or this build has no receiver (the event is not marked as sent)
    @discardableResult
    private func enqueue(_ event: Event) -> Bool {
        guard isEnabled, endpoint != nil else { return false }
        var pending = defaults.array(forKey: Self.pendingKey) as? [[String: String]] ?? []
        pending.append([
            "event": event.rawValue,
            "id": installID,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "at": ISO8601DateFormatter().string(from: Date())
        ])
        defaults.set(Array(pending.suffix(20)), forKey: Self.pendingKey)
        return true
    }

    /// Sends queued events; anything that fails stays queued for the next launch or dictation
    private func flush() {
        guard isEnabled, let endpoint, !flushing,
              let pending = defaults.array(forKey: Self.pendingKey) as? [[String: String]], !pending.isEmpty else { return }
        flushing = true
        Task {
            var sent = 0
            for event in pending {
                var request = URLRequest(url: endpoint, timeoutInterval: 20)
                request.httpMethod = "POST"
                request.setValue("text/plain;charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: event)
                guard let (_, response) = try? await URLSession.shared.data(for: request),
                      let status = (response as? HTTPURLResponse)?.statusCode, status < 400 else { break }
                sent += 1
            }
            // Re-read: events queued while we were sending must not be dropped
            let current = defaults.array(forKey: Self.pendingKey) as? [[String: String]] ?? []
            defaults.set(Array(current.dropFirst(min(sent, current.count))), forKey: Self.pendingKey)
            flushing = false
            if sent > 0, current.count > sent { flush() }
        }
    }

    private static func currentWeek() -> String {
        let cal = Calendar(identifier: .iso8601)
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return "\(c.yearForWeekOfYear ?? 0)-W\(c.weekOfYear ?? 0)"
    }
}
