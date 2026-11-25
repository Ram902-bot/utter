import SwiftUI

/// The app's main window: dictation status and controls on top, history below.
struct MainView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    let appDelegate: AppDelegate

    var body: some View {
        if appState.onboardingComplete {
            mainContent
        } else {
            OnboardingView()
                .navigationTitle("Set up Utter")
                .onAppear { appDelegate.openMainWindow = { openWindow(id: "main") } }
        }
    }

    private var mainContent: some View {
        Group {
            if DocsMode.isOn {
                // Screenshots only: same sidebar and pages without the glass split view, which can't be captured
                HStack(spacing: 0) {
                    sidebar.frame(width: 230).background(Color(nsColor: .windowBackgroundColor))
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail
                }
            }
        }
        .onAppear {
            // Lets the Dock icon and menu bar reopen this window after it's closed
            appDelegate.openMainWindow = { openWindow(id: "main") }
        }
    }

    private var sidebar: some View {
            VStack(spacing: 0) {
                brandHeader
                List(selection: pageBinding) {
                    Section("Workspace") {
                        HStack {
                            Label("History", systemImage: "clock.arrow.circlepath")
                            Spacer()
                            if !appState.history.entries.isEmpty {
                                Text("\(appState.history.entries.count)")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tag(AppPage.history)
                        HStack {
                            Label("Vocabulary", systemImage: "character.book.closed")
                            Spacer()
                            if !appState.vocabulary.terms.isEmpty {
                                Text("\(appState.vocabulary.terms.count)")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tag(AppPage.vocabulary)
                    }
                    Section("App") {
                        HStack {
                            Label("Setup", systemImage: "checklist")
                            Spacer()
                            Image(systemName: appState.setupHealthy ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundColor(appState.setupHealthy ? .green : .orange)
                                .help(appState.setupHealthy ? "Everything is set up" : "Something needs your attention")
                                .accessibilityLabel(appState.setupHealthy ? "Setup complete" : "Setup needs attention")
                        }
                        .tag(AppPage.setup)
                        Label("Settings", systemImage: "gearshape")
                            .tag(AppPage.settings)
                    }
                }
                .listStyle(.sidebar)
                sidebarStatus
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    }

    @ViewBuilder
    private var detail: some View {
            switch appState.selectedPage {
            case .history:
                VStack(spacing: 0) {
                    statusBar
                    Divider()
                    HistoryView()
                }
                .navigationTitle("History")
            case .vocabulary:
                VocabularyView()
                    .navigationTitle("Vocabulary")
            case .setup:
                OnboardingView(embedded: true)
                    .navigationTitle("Setup")
            case .settings:
                SettingsView()
                    .navigationTitle("Settings")
            }
    }

    private var pageBinding: Binding<AppPage?> {
        Binding(get: { appState.selectedPage },
                set: { if let page = $0 { appState.selectedPage = page } })
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text("Utter")
                    .font(.system(size: 14, weight: .semibold))
                Text("Voice to text, on this Mac")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var sidebarStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .available(let version) = appState.updateChecker.state {
                Button {
                    appState.updateChecker.installUpdate()
                } label: {
                    Label("Update to \(version)", systemImage: "arrow.down.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                Divider()
            }
            HStack(spacing: 8) {
                statusIndicator
                Text(statusTitle)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            HStack(spacing: 4) {
                ForEach(["⌘", "⇧", "Space"], id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12)))
                }
                Text("to dictate")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        .padding(12)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(statusDetail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if appState.status == .setupFailed {
                Button("Retry Setup") { appState.retrySetup() }
            } else {
                Button(action: { appState.toggleRecording() }) {
                    Label(appState.status == .recording ? "Stop" : "Dictate",
                          systemImage: appState.status == .recording ? "stop.fill" : "mic.fill")
                        .frame(minWidth: 76)
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.status == .recording ? .red : .accentColor)
                .controlSize(.large)
                .disabled(appState.status == .settingUp || appState.status == .transcribing)
                .help("Or press Cmd+Shift+Space anywhere")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        let engine = appState.transcriptionEngine
        switch appState.status {
        case .settingUp:
            if engine.isDownloading && engine.downloadProgress < 1.0 {
                ProgressView(value: engine.downloadProgress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
        case .setupFailed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .recording:
            Circle().fill(Color.red).frame(width: 8, height: 8)
        case .transcribing:
            ProgressView().controlSize(.small)
        case .idle:
            Circle().fill(Color.green).frame(width: 8, height: 8)
        }
    }

    private var statusTitle: String {
        switch appState.status {
        case .settingUp: return "Setting up"
        case .setupFailed: return "Setup failed"
        case .idle: return "Ready"
        case .recording: return "Listening..."
        case .transcribing: return "Transcribing..."
        }
    }

    private var statusDetail: String {
        let engine = appState.transcriptionEngine
        switch appState.status {
        case .settingUp:
            if engine.isDownloading && engine.downloadProgress < 1.0 {
                return "Downloading the speech model, \(Int(engine.downloadProgress * 100))%"
            }
            return engine.setupStatus.isEmpty ? "Loading the speech model" : engine.setupStatus
        case .setupFailed:
            return engine.setupError ?? "Couldn't load the speech model"
        case .idle:
            return "Press Cmd+Shift+Space anywhere to dictate"
        case .recording:
            return "Press Cmd+Shift+Space again to stop"
        case .transcribing:
            return "Turning your speech into text on this Mac"
        }
    }
}
