import SwiftUI
import ApplicationServices

struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @State private var query = DocsMode.searchQuery
    @State private var copiedID: UUID?
    @State private var confirmClear = false
    @State private var fixing: DictationEntry?
    @State private var accessibilityOK = AXIsProcessTrusted()

    private var history: HistoryStore { appState.history }

    private var filtered: [DictationEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.text.localizedCaseInsensitiveContains(q) || ($0.appName ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    private var groups: [(title: String, items: [DictationEntry])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { day in
            (dayTitle(day), byDay[day]!.sorted { $0.date > $1.date })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            updateBanner

            if appState.legacyAppRunning {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("The old Evertalk app is still running and is using Cmd+Shift+Space.")
                        .font(.system(size: 12))
                    Spacer(minLength: 8)
                    Button("Quit Evertalk") { appState.quitLegacyApp() }
                }
                .padding(12)
                .background(Color.orange.opacity(0.12))
                Divider()
            }

            if history.lastUnpasted != nil && !appState.accessibilityGranted {
                accessibilityBanner
            }

            if !history.isEnabled {
                emptyState(icon: "clock.badge.xmark",
                           title: "History is off",
                           message: "Turn it on in Settings to keep recent dictations here.",
                           action: ("Open Settings", { appState.selectedPage = .settings }))
            } else if history.entries.isEmpty {
                emptyState(icon: "mic",
                           title: "Nothing yet",
                           message: "Press Cmd+Shift+Space and speak. Everything you dictate shows up here so you can copy it again.",
                           action: nil)
            } else if filtered.isEmpty {
                emptyState(icon: "magnifyingglass", title: "No matches", message: "Nothing you said matches \"\(query)\".", action: nil)
            } else {
                List {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.items) { entry in
                                row(entry)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 440)
        .searchable(text: $query, placement: .toolbar, prompt: "Search what you said")
        .onAppear {
            history.applyRetention()
            accessibilityOK = AXIsProcessTrusted()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityOK = AXIsProcessTrusted()
        }
        .sheet(item: $fixing) { entry in
            FixWordSheet(entry: entry)
                .environmentObject(appState)
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { history.clearAll() }
        } message: {
            Text("This removes every saved dictation from this Mac. It can't be undone.")
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var updateBanner: some View {
        let updater = appState.updateChecker
        switch updater.state {
        case .available(let version) where !updater.bannerDismissed:
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Utter \(version) is available")
                        .font(.system(size: 12, weight: .semibold))
                    Text("You're on \(updater.currentVersion). Updating takes about a minute and keeps your history.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                Link("What's New", destination: updater.notesURL(for: version))
                    .font(.system(size: 12))
                Button("Later") { updater.bannerDismissed = true }
                Button("Update Now") { updater.installUpdate() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.08))
            Divider()
        case .updating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Updating Utter... it will reopen by itself.")
                    .font(.system(size: 12))
                Spacer()
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.08))
            Divider()
        case .failed(let reason):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update didn't finish: \(reason)")
                        .font(.system(size: 12))
                        .lineLimit(2)
                    if SelfService.isManagedMac {
                        Text("On a company Mac, run \"Make Me Admin\" in \(SelfService.appName) first, then try again.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if SelfService.isManagedMac {
                    Button("Open \(SelfService.appName)") { SelfService.open() }
                }
                Button("Try Again") { updater.installUpdate() }
            }
            .padding(12)
            .background(Color.orange.opacity(0.1))
            Divider()
        default:
            EmptyView()
        }
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("Your last dictation didn't paste. Utter needs Accessibility access again, which often happens after an update. Copy it below for now.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Fix Access") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }

    private func row(_ entry: DictationEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 62, alignment: .trailing)
                .padding(.top, 11)

            VStack(alignment: .leading, spacing: 8) {
                Text(highlighted(entry.text))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if let app = entry.appName {
                        Text(app)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    if let engine = entry.engine {
                        Label(engine, systemImage: "cloud")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if !entry.pasted {
                        Label("Not pasted", systemImage: "exclamationmark.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    Text("\(entry.wordCount) words")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Button {
                        copy(entry)
                    } label: {
                        Label(copiedID == entry.id ? "Copied" : "Copy",
                              systemImage: copiedID == entry.id ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .help("Copy to clipboard")

                    Button {
                        fixing = entry
                    } label: {
                        Label("Fix", systemImage: "wand.and.stars")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .help("A word came out wrong? Fix it and Utter remembers")

                    Button(role: .destructive) {
                        history.delete(entry)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .help("Delete from history")
                    .accessibilityLabel("Delete")
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(entry.pasted ? Color(nsColor: .separatorColor) : Color.orange.opacity(0.55))
            )
        }
        .contextMenu {
            Button("Copy") { copy(entry) }
            Button("Fix a Word...") { fixing = entry }
            Button("Delete", role: .destructive) { history.delete(entry) }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 11))
            Text(history.isEnabled
                 ? "Saved only on this Mac. Text only, no audio. Kept \(retentionLabel)."
                 : "History is off. Nothing is saved.")
                .font(.system(size: 11))
            Spacer()
            if !history.entries.isEmpty {
                Button("Clear All…") { confirmClear = true }
                    .controlSize(.small)
            }
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func emptyState(icon: String, title: String, message: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let action {
                Button(action.0, action: action.1)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    /// Entry text in soft grey, with every search match in full-strength text on a highlight
    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = Color.primary.opacity(0.72)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return result }
        var searchRange = text.startIndex..<text.endIndex
        while let match = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            if let attrRange = Range(match, in: result) {
                result[attrRange].foregroundColor = Color.primary
                result[attrRange].backgroundColor = Color.yellow.opacity(0.4)
                result[attrRange].inlinePresentationIntent = .stronglyEmphasized
            }
            searchRange = match.upperBound..<text.endIndex
        }
        return result
    }

    private var retentionLabel: String {
        switch history.retentionDays {
        case 0: return "until you delete it"
        case 1: return "for 1 day"
        default: return "for \(history.retentionDays) days"
        }
    }

    private func copy(_ entry: DictationEntry) {
        appState.pasteManager.copyToClipboard(entry.text)
        copiedID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedID == entry.id { copiedID = nil }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month())
    }
}
