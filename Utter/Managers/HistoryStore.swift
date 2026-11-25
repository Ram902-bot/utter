import Foundation
import Combine

/// One finished dictation. Text only: audio is never stored.
struct DictationEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let text: String
    let appName: String?
    var pasted: Bool
    /// "cloud: host" when transcribed by a cloud service; nil = on this Mac
    var engine: String?

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

/// Keeps recent dictations on this Mac so text that didn't paste (or got lost) can be copied again.
/// Stored as JSON in Application Support, readable only by the current user, pruned by retention.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [DictationEntry] = []

    static let enabledKey = "historyEnabled"
    static let retentionKey = "historyRetentionDays"
    /// Days to keep entries; 0 means keep until deleted
    static let retentionOptions = [1, 7, 30, 90, 0]

    private let fileURL: URL
    private let defaults: UserDefaults

    var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    var retentionDays: Int {
        guard let value = defaults.object(forKey: Self.retentionKey) as? Int,
              Self.retentionOptions.contains(value) else { return 7 }
        return value
    }

    /// The most recent dictation, if it failed to paste.
    var lastUnpasted: DictationEntry? {
        guard let last = entries.first, !last.pasted else { return nil }
        return last
    }

    init(fileURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = AppPaths.supportDirectory.appendingPathComponent("history.json")
        }
        load()
    }

    @discardableResult
    func add(text: String, appName: String?, pasted: Bool, engine: String? = nil) -> DictationEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !trimmed.isEmpty else { return nil }
        let entry = DictationEntry(id: UUID(), date: Date(), text: trimmed, appName: appName, pasted: pasted, engine: engine)
        entries.insert(entry, at: 0)
        prune()
        save()
        return entry
    }

    /// Replace an entry's text (after the user fixes a word)
    func updateText(of entry: DictationEntry, to text: String) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let old = entries[i]
        entries[i] = DictationEntry(id: old.id, date: old.date, text: text, appName: old.appName,
                                    pasted: old.pasted, engine: old.engine)
        save()
    }

    func delete(_ entry: DictationEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clearAll() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Re-apply retention (called when the setting changes or the window opens).
    func applyRetention() {
        let before = entries.count
        prune()
        if entries.count != before { save() }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled { clearAll() }
        objectWillChange.send()
    }

    func setRetentionDays(_ days: Int) {
        defaults.set(days, forKey: Self.retentionKey)
        applyRetention()
        objectWillChange.send()
    }

    // MARK: - Persistence

    private func prune() {
        guard retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        entries.removeAll { $0.date < cutoff }
    }

    private func load() {
        guard isEnabled else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([DictationEntry].self, from: data)) ?? []
        applyRetention()
    }

    private func save() {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("History save failed: \(error.localizedDescription)")
        }
    }
}
