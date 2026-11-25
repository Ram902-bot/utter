import Foundation

/// "When it hears X, write Y"
struct Replacement: Codable, Identifiable, Equatable {
    var id = UUID()
    var heard: String
    var write: String
}

/// Words the user wants Utter to get right. Terms are passed to Whisper as a hint before it
/// listens; replacements are applied to the text afterwards. Stored on this Mac only.
@MainActor
final class VocabularyStore: ObservableObject {
    @Published private(set) var terms: [String] = []
    @Published private(set) var replacements: [Replacement] = []

    /// Whisper's hint is capped near 220 tokens, so only this many terms are sent
    static let maxHintTerms = 100

    private let fileURL: URL

    private struct Stored: Codable {
        var terms: [String]
        var replacements: [Replacement]
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppPaths.supportDirectory.appendingPathComponent("vocabulary.json")
        load()
    }

    var isEmpty: Bool { terms.isEmpty && replacements.isEmpty }

    /// Hint text for Whisper: replacement targets first (they matter most), then terms
    var hintText: String? {
        var seen = Set<String>()
        let ordered = (replacements.map(\.write) + terms).filter { term in
            let key = term.lowercased()
            guard !term.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
        guard !ordered.isEmpty else { return nil }
        return " " + ordered.prefix(Self.maxHintTerms).joined(separator: ", ") + "."
    }

    // MARK: - Terms

    /// Adds terms pulled out of a Markdown file. Returns how many were new.
    @discardableResult
    func importMarkdown(at url: URL) throws -> Int {
        let text = try String(contentsOf: url, encoding: .utf8)
        return add(Self.extractTerms(fromMarkdown: text))
    }

    /// Terms found in Markdown files that aren't in the list yet (for the review step)
    func previewImport(from urls: [URL]) -> (terms: [String], unreadable: Int) {
        var found: [String] = []
        var seen = Set(terms.map { $0.lowercased() })
        var unreadable = 0
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { unreadable += 1; continue }
            for term in Self.extractTerms(fromMarkdown: text) where !seen.contains(term.lowercased()) {
                found.append(term)
                seen.insert(term.lowercased())
            }
        }
        return (found, unreadable)
    }

    @discardableResult
    func add(_ newTerms: [String]) -> Int {
        var existing = Set(terms.map { $0.lowercased() })
        var added = 0
        for raw in newTerms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(CharacterSet(charactersIn: "._-+#"))))
            guard term.count >= 2, term.count <= 40, !existing.contains(term.lowercased()) else { continue }
            terms.append(term)
            existing.insert(term.lowercased())
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    func remove(_ term: String) {
        terms.removeAll { $0 == term }
        save()
    }

    func clearTerms() {
        terms.removeAll()
        save()
    }

    // MARK: - Replacements

    func addReplacement(heard: String, write: String) {
        let h = heard.trimmingCharacters(in: .whitespaces)
        let w = write.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, !w.isEmpty else { return }
        replacements.removeAll { $0.heard.lowercased() == h.lowercased() }
        replacements.append(Replacement(heard: h, write: w))
        save()
    }

    func removeReplacement(_ replacement: Replacement) {
        replacements.removeAll { $0.id == replacement.id }
        save()
    }

    /// Whole-word, case-insensitive replacements on the finished text
    func apply(to text: String) -> String {
        replacements.reduce(text) { Self.replaceWholeWord($1.heard, with: $1.write, in: $0) }
    }

    static func wholeWordRegex(_ word: String) -> NSRegularExpression? {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func replaceWholeWord(_ word: String, with replacement: String, in text: String) -> String {
        guard let regex = wholeWordRegex(word) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    static func containsWholeWord(_ word: String, in text: String) -> Bool {
        guard let regex = wholeWordRegex(word) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - Markdown term extraction

    /// Pulls out words that are likely jargon: `code`, **bold**, short headings, CamelCase,
    /// ACRONYMS, snake_case / dotted.names, and capitalised words used more than once.
    static func extractTerms(fromMarkdown text: String) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        func bump(_ term: String, by weight: Int = 1) {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, t.count <= 40, !stopwords.contains(t.lowercased()), isSpeakable(t) else { return }
            if counts[t] == nil { order.append(t) }
            counts[t, default: 0] += weight
        }
        func matches(_ pattern: String, in s: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
                let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
                return Range(r, in: s).map { String(s[$0]) }
            }
        }

        // Skip fenced code blocks: they're full of syntax, not spoken words
        let body = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)

        for code in matches("`([^`\\n]{2,40})`", in: body) where code.split(separator: " ").count <= 2 {
            bump(code, by: 3)
        }
        for bold in matches("\\*\\*([^*\\n]{2,40})\\*\\*|__([^_\\n]{2,40})__", in: body) {
            let words = bold.split(separator: " ")
            if words.count <= 2, words.allSatisfy({ $0.first?.isUppercase == true }) { bump(bold, by: 3) }
        }
        for heading in matches("(?m)^#{1,6}\\s+(.+)$", in: body) {
            let clean = heading.replacingOccurrences(of: "[*_`]", with: "", options: .regularExpression)
            // Only name-like headings ("VibeCraft", "Fast Commissions"), not "Key decisions"
            let words = clean.split(separator: " ")
            if words.count <= 2, words.allSatisfy({ $0.first?.isUppercase == true }) { bump(clean, by: 2) }
        }

        let plain = body.replacingOccurrences(of: "[`*_#>\\[\\]()]", with: " ", options: .regularExpression)
        for word in matches("\\b([A-Z][a-z]+[A-Z][A-Za-z0-9]*|[a-z]+[A-Z][A-Za-z0-9]+)\\b", in: plain) { bump(word, by: 2) }  // CamelCase
        for word in matches("\\b([A-Z]{2,6}s?)\\b", in: plain) { bump(word, by: 2) }                                        // ACRONYMS
        for word in matches("\\b([a-z0-9]+(?:[_.][a-z0-9]+)+)\\b", in: plain) where !word.contains("..") { bump(word) }       // snake_case
        // Capitalised words that aren't starting a sentence
        for word in matches("(?<=[a-z,;:] )([A-Z][a-z]{2,})\\b", in: plain) { bump(word) }

        return order
            .filter { counts[$0, default: 0] >= 2 }
            .sorted { counts[$0, default: 0] > counts[$1, default: 0] }
    }

    /// Not a file path, number, URL or code call, and has at least one letter
    private static func isSpeakable(_ t: String) -> Bool {
        if t.rangeOfCharacter(from: .letters) == nil { return false }
        if t.contains("/") || t.contains("(") || t.contains("=") || t.contains("://") || t.hasSuffix(".") || t.lowercased() == "e.g" || t.lowercased() == "i.e" { return false }
        if t.range(of: "\\.(md|png|jpg|jpeg|gif|pdf|csv|json|ya?ml|txt|html?|swift|py|js|ts|tsx|sql|sh)$",
                   options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if t.range(of: "^[0-9]", options: .regularExpression) != nil { return false }
        return true
    }

    private static let stopwords: Set<String> = [
        // everyday acronyms and words Whisper already gets right
        "ui", "ux", "us", "uk", "pm", "am", "qa", "pdf", "dm", "not", "fy", "ytd", "qtd", "eta", "ceo", "cto",
        "cfo", "vp", "hr", "it", "ai", "llm", "faq", "tbd", "fyi", "asap", "eod", "eow", "kpi", "okr", "roi",
        "csv", "sql", "json", "html", "css", "gb", "mb", "ok", "na", "sync", "ga", "beta", "alpha", "new",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "mon", "tue",
        "wed", "thu", "fri", "sat", "sun", "today", "yesterday", "tomorrow", "week", "month", "year", "pod",
        "team", "customer", "customers", "user", "users", "admin", "feature", "features", "release", "update",
        "decision", "decisions", "risk", "risks", "scope", "plan", "draft", "final", "version", "link", "links",
        "related", "readme", "setup", "apple", "developer", "slack", "github", "commissions",
        "the", "this", "that", "these", "those", "and", "or", "but", "if", "then", "when", "what", "how",
        "why", "who", "where", "for", "with", "from", "into", "onto", "about", "after", "before", "note",
        "notes", "example", "examples", "todo", "overview", "summary", "intro", "introduction", "details",
        "background", "context", "goal", "goals", "steps", "step", "status", "owner", "owners", "date",
        "open", "questions", "question", "next", "done", "yes", "no", "ok", "id", "url", "api", "faq",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february",
        "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"
    ]

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        terms = stored.terms
        replacements = stored.replacements
    }

    private func save() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Stored(terms: terms, replacements: replacements))
            try data.write(to: fileURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("Vocabulary save failed: \(error.localizedDescription)")
        }
    }
}
