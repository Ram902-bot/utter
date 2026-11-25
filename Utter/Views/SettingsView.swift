import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var launchAtLogin = false
    @State private var playSounds = true
    @State private var showOverlayEnabled = true
    @State private var historyEnabled = true
    @State private var appearance = AppearanceMode.system.rawValue
    @State private var retentionDays = 7
    @State private var shareUsage = true
    @State private var engine = SpeechEngineKind.current
    @State private var localModel = LocalModel.current
    @State private var provider = CloudProvider.current
    @State private var baseURL = CloudSettings.load().baseURL
    @State private var cloudModel = CloudSettings.load().model
    @State private var keyInput = ""
    @State private var keySaved = false
    @State private var testMessage: String?
    @State private var testing = false
    @State private var freedMessage: String?

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .onChange(of: appearance) { _, newValue in
                    appState.appearance = newValue
                    appState.applyAppearance()
                }

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }

            Section("Dictation") {
                Toggle("Play sounds", isOn: $playSounds)
                    .onChange(of: playSounds) { _, newValue in
                        appState.playSounds = newValue
                    }

                LabeledContent("Show floating indicator") {
                    HStack(spacing: 10) {
                        if showOverlayEnabled {
                            Button("Reset Position") {
                                NotificationCenter.default.post(name: .resetOverlayPosition, object: nil)
                            }
                            .controlSize(.small)
                        }
                        Toggle("Show floating indicator", isOn: $showOverlayEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: showOverlayEnabled) { _, newValue in
                                appState.showOverlayEnabled = newValue
                                NotificationCenter.default.post(
                                    name: .overlayVisibilityChanged,
                                    object: nil,
                                    userInfo: ["enabled": newValue]
                                )
                            }
                    }
                }
            }

            if FeatureFlags.speechEngineChoice {
            Section {
                Picker("Engine", selection: $engine) {
                    ForEach(SpeechEngineKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: engine) { _, newValue in
                    UserDefaults.standard.set(newValue.rawValue, forKey: SpeechEngineKind.defaultsKey)
                }

                if engine == .local {
                    localEngineRows
                } else {
                    cloudEngineRows
                }
            } header: {
                Text("Speech engine")
            } footer: {
                Text(engine == .local
                     ? "Speech is turned into text on this Mac. Audio never leaves it."
                     : "Audio is sent to \(hostLabel) for each dictation. Your key stays in the macOS Keychain. If the service fails, Utter uses the on-device model instead.")
                    .font(.caption)
                    .foregroundColor(engine == .local ? .secondary : .orange)
            }
            }

            Section {
                Toggle("Keep history", isOn: $historyEnabled)
                    .onChange(of: historyEnabled) { _, newValue in
                        appState.history.setEnabled(newValue)
                    }

                if historyEnabled {
                    Picker("Keep for", selection: $retentionDays) {
                        Text("1 day").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("Until I delete it").tag(0)
                    }
                    .onChange(of: retentionDays) { _, newValue in
                        appState.history.setRetentionDays(newValue)
                    }
                }
            } header: {
                Text("History")
            } footer: {
                Text("Dictations are saved as text on this Mac only, and audio is never saved. Turning history off deletes it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Share anonymous usage counts", isOn: $shareUsage)
                    .onChange(of: shareUsage) { _, newValue in appState.usage.setEnabled(newValue) }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Tells Ram how many people install Utter and use it each week. Sends a random ID, the Utter version and the macOS version. Never your name, what you say, your history or your words.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("About") {
                LabeledContent("Speech model", value: "Whisper Small (English), on this Mac")
                LabeledContent("Version") {
                    switch appState.updateChecker.state {
                    case .available(let version):
                        Button("Update to \(version)") { appState.updateChecker.installUpdate() }
                    case .updating:
                        Text("Updating...").foregroundColor(.secondary)
                    case .failed:
                        Button("Update failed - retry") { appState.updateChecker.installUpdate() }
                    case .idle:
                        Text(appState.updateChecker.currentVersion).foregroundColor(.secondary)
                    }
                }
                Link("View on GitHub", destination: URL(string: "https://github.com/Ram902-bot/utter")!)
                Button("Run Setup Again") { appState.restartOnboarding() }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            playSounds = appState.playSounds
            showOverlayEnabled = appState.showOverlayEnabled
            historyEnabled = appState.history.isEnabled
            retentionDays = appState.history.retentionDays
            appearance = appState.appearance
            shareUsage = appState.usage.isEnabled
            keySaved = KeychainStore.read(account: provider.rawValue) != nil
        }
    }

    // MARK: - Speech engine rows

    @ViewBuilder
    private var localEngineRows: some View {
        let engineState = appState.transcriptionEngine
        Picker("Model", selection: $localModel) {
            ForEach(LocalModel.allCases) { model in
                Text(model.label + (engineState.isDownloaded(model) ? "" : "  (download)")).tag(model)
            }
        }
        .onChange(of: localModel) { _, newValue in
            engineState.switchModel(to: newValue)
        }

        Text(localModel.detail)
            .font(.caption)
            .foregroundColor(.secondary)

        if engineState.isDownloading {
            ProgressView(value: engineState.downloadProgress) {
                Text("Downloading \(localModel.label)... \(Int(engineState.downloadProgress * 100))%")
                    .font(.caption)
            }
        } else if !engineState.isModelReady && !engineState.setupFailed {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading model...").font(.caption).foregroundColor(.secondary)
            }
        }

        if LocalModel.allCases.contains(where: { $0 != localModel && engineState.isDownloaded($0) }) {
            HStack {
                Button("Remove Other Models") {
                    let mb = engineState.removeUnusedModels()
                    freedMessage = "Freed \(mb) MB"
                }
                if let freedMessage {
                    Text(freedMessage).font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var cloudEngineRows: some View {
        Picker("Provider", selection: $provider) {
            ForEach(CloudProvider.allCases) { Text($0.label).tag($0) }
        }
        .onChange(of: provider) { _, newValue in
            baseURL = newValue.defaultBaseURL
            cloudModel = newValue.defaultModel
            keyInput = ""
            keySaved = KeychainStore.read(account: newValue.rawValue) != nil
            testMessage = nil
            saveCloudSettings()
        }

        if provider == .custom {
            TextField("Base URL", text: $baseURL, prompt: Text("https://.../v1"))
                .onSubmit(saveCloudSettings)
        }

        TextField("Model", text: $cloudModel)
            .onSubmit(saveCloudSettings)

        HStack {
            SecureField("API key", text: $keyInput, prompt: Text(keySaved ? "Saved in Keychain" : "Paste your key"))
            Button(keySaved && keyInput.isEmpty ? "Remove" : "Save") {
                if keySaved && keyInput.isEmpty {
                    KeychainStore.delete(account: provider.rawValue)
                    keySaved = false
                } else {
                    keySaved = KeychainStore.save(keyInput.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  account: provider.rawValue)
                    keyInput = ""
                }
                saveCloudSettings()
            }
            .disabled(!keySaved && keyInput.isEmpty)
        }

        HStack {
            Button(testing ? "Testing..." : "Test Connection") { testConnection() }
                .disabled(testing || !keySaved)
            if let testMessage {
                Text(testMessage)
                    .font(.caption)
                    .foregroundColor(testMessage.hasPrefix("Works") ? .green : .orange)
                    .lineLimit(2)
            } else if let error = appState.cloudError {
                Text("Last dictation fell back to this Mac: \(error)")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }
        }
    }

    private var hostLabel: String {
        URL(string: baseURL)?.host ?? provider.label
    }

    private func saveCloudSettings() {
        CloudSettings(provider: provider,
                      baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                      model: cloudModel.trimmingCharacters(in: .whitespaces)).save()
    }

    /// Sends half a second of silence to check the URL, model and key
    private func testConnection() {
        saveCloudSettings()
        guard let cloud = CloudTranscriber.configured() else {
            testMessage = "Needs an https URL, a model and a saved key"
            return
        }
        testing = true
        testMessage = nil
        Task {
            do {
                _ = try await cloud.transcribe(samples: Array(repeating: 0, count: 8_000))
                testMessage = "Works - \(cloud.settings.hostLabel) answered"
                appState.cloudError = nil
            } catch {
                testMessage = error.localizedDescription
            }
            testing = false
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            appState.launchAtLogin = enabled
        } catch {
            print("Failed to set launch at login: \(error)")
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let overlayVisibilityChanged = Notification.Name("overlayVisibilityChanged")
    static let resetOverlayPosition = Notification.Name("resetOverlayPosition")
}
