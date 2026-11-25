import SwiftUI
import AVFoundation
import ApplicationServices

/// First-launch checklist: microphone, Accessibility, speech model, first dictation.
/// Ticks update live while the user flips switches in System Settings.
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    /// true = shown as the Setup page in the sidebar (no Skip / Get Started, adds Updates)
    var embedded = false
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityOK = AXIsProcessTrusted()
    @State private var startCount = 0

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var micOK: Bool { micStatus == .authorized }
    private var modelOK: Bool { appState.transcriptionEngine.isModelReady }
    private var triedIt: Bool {
        embedded ? !appState.history.entries.isEmpty : appState.history.entries.count > startCount
    }
    private var canContinue: Bool { micOK && accessibilityOK }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    if appState.legacyAppRunning {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text("The old EverTalk app is still running and is using Cmd+Shift+Space. Quit it so Utter's shortcut works.")
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button("Quit EverTalk") { appState.quitLegacyApp() }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
                    }

                    VStack(spacing: 12) {
                        step(number: 1,
                             title: "Allow the microphone",
                             detail: "So Utter can hear you. Audio is turned into text on this Mac.",
                             done: micOK) {
                            if micStatus == .notDetermined {
                                Button("Allow") {
                                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                                        DispatchQueue.main.async { refresh() }
                                    }
                                }
                            } else {
                                Button("Open Settings") { openPane("Privacy_Microphone") }
                            }
                        }

                        step(number: 2,
                             title: "Allow Accessibility",
                             detail: accessibilityDetail,
                             done: accessibilityOK) {
                            VStack(alignment: .trailing, spacing: 6) {
                                if SelfService.isManagedMac {
                                    Button("Open \(SelfService.appName)") { SelfService.open() }
                                }
                                Button("Open Settings") {
                                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                                    _ = AXIsProcessTrustedWithOptions(options)
                                    openPane("Privacy_Accessibility")
                                }
                            }
                        }

                        step(number: 3,
                             title: "Speech model",
                             detail: modelDetail,
                             done: modelOK) {
                            if appState.status == .setupFailed {
                                Button("Retry") { appState.retrySetup() }
                            } else if appState.transcriptionEngine.isDownloading {
                                ProgressView(value: appState.transcriptionEngine.downloadProgress)
                                    .frame(width: 80)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }

                        step(number: 4,
                             title: "Try it",
                             detail: "Click into any text box, press Cmd+Shift+Space, say a sentence, then press it again.",
                             done: triedIt) {
                            Text("⌘ ⇧ Space")
                                .font(.system(size: 12, weight: .medium).monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                        }
                    }

                    if embedded {
                        updatesSection
                    } else {
                        Text("Utter shares anonymous usage counts (a random ID and version numbers, never what you say) so we know if it's working for people. You can switch this off in Settings.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(32)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }

            if !embedded {
                footer
            }
        }
        .onAppear {
            startCount = appState.history.entries.count
            refresh()
        }
        .onReceive(poll) { _ in refresh() }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button("Skip for Now") { appState.completeOnboarding() }
                    .buttonStyle(.borderless)
                Spacer()
                if !canContinue {
                    Text("Steps 1 and 2 are needed for Utter to work")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Button("Get Started") { appState.completeOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canContinue)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        let updater = appState.updateChecker
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates")
                .font(.system(size: 14, weight: .semibold))
            HStack(spacing: 12) {
                switch updater.state {
                case .available(let version):
                    Image(systemName: "arrow.down.circle.fill").foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Utter \(version) is available").font(.system(size: 13, weight: .medium))
                        Text("You're on \(updater.currentVersion).").font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Link("What's New", destination: updater.notesURL(for: version)).font(.system(size: 12))
                    Button("Update Now") { updater.installUpdate() }.buttonStyle(.borderedProminent)
                case .updating:
                    ProgressView().controlSize(.small)
                    Text("Updating... Utter will reopen by itself.").font(.system(size: 13))
                    Spacer()
                case .failed(let reason):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("Update didn't finish: \(reason)").font(.system(size: 12)).lineLimit(2)
                    Spacer()
                    Button("Try Again") { updater.installUpdate() }
                case .idle:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Up to date").font(.system(size: 13, weight: .medium))
                        Text("Version \(updater.currentVersion). Utter checks for updates by itself.")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Check Now") { Task { await updater.checkForUpdates() } }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(embedded ? "Setup" : "Set up Utter")
                    .font(.system(size: 22, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var accessibilityDetail: String {
        let base = "So Utter can type into the app you're using. In the list, switch Utter on. If it's already on, switch it off and on again."
        guard SelfService.isManagedMac else { return base }
        return "On a company Mac you need admin rights first: open \(SelfService.appName), search \"Make Me Admin\" and run it. Then: " + base.prefix(1).lowercased() + base.dropFirst()
    }

    private var headerSubtitle: String {
        guard embedded else { return "Two permissions and you're ready. Takes about a minute." }
        let missing = [micOK, accessibilityOK, modelOK, !appState.legacyAppRunning].filter { !$0 }.count
        return missing == 0 ? "Everything is set up." : "\(missing) \(missing == 1 ? "thing needs" : "things need") your attention."
    }

    private var modelDetail: String {
        let engine = appState.transcriptionEngine
        if engine.isModelReady { return "Ready. Runs on this Mac." }
        if engine.isDownloading {
            return "Downloading once (about 490 MB), \(Int(engine.downloadProgress * 100))%. You can carry on with the other steps."
        }
        if appState.status == .setupFailed { return engine.setupError ?? "Download failed." }
        return "Preparing the speech model..."
    }

    private func step<Action: View>(number: Int, title: String, detail: String, done: Bool,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.primary.opacity(0.08))
                    .frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .accessibilityLabel(done ? "Step \(number) done" : "Step \(number)")

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if !done {
                action()
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func refresh() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityOK = AXIsProcessTrusted()
    }

    private func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
