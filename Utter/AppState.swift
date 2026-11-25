import SwiftUI
import AVFoundation
import ApplicationServices
import Combine

enum RecordingStatus {
    case settingUp
    case setupFailed
    case idle
    case recording
    case transcribing
}

enum DictationResult: Equatable {
    case pasted
    case copiedOnly
    case failed(String)
}

enum AppPage: String, Hashable {
    case history
    case vocabulary
    case setup
    case settings
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var status: RecordingStatus = .settingUp
    @Published var transcription: String = ""
    @Published var errorMessage: String?
    @Published var showOverlay: Bool = true  // Show during setup

    // Settings
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("playSounds") var playSounds: Bool = true
    @AppStorage("showOverlayEnabled") var showOverlayEnabled: Bool = true
    @AppStorage("appearance") var appearance: String = AppearanceMode.system.rawValue
    @AppStorage("onboardingComplete") var onboardingComplete: Bool = false

    // Recording indicator
    @Published var levels: [Float] = Array(repeating: 0, count: 9)
    @Published var recordingStartedAt: Date?
    @Published var lastResult: DictationResult?
    /// Last cloud failure (shown in Settings); cleared on a successful cloud test
    @Published var cloudError: String?

    // Permission status, refreshed every couple of seconds (for the sidebar Setup tick)
    @Published private(set) var micGranted = DocsMode.isOn || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published private(set) var accessibilityGranted = DocsMode.isOn || AXIsProcessTrusted()
    private var permissionTimer: Timer?

    /// The old Evertalk app still running holds Cmd+Shift+Space, so Utter's shortcut can't work
    @Published private(set) var legacyAppRunning = !DocsMode.isOn && AppState.isLegacyAppRunning()

    var setupHealthy: Bool {
        micGranted && accessibilityGranted && transcriptionEngine.isModelReady && !legacyAppRunning
    }

    static func isLegacyAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: AppPaths.legacyBundleID).isEmpty
    }

    /// Quits the old Evertalk app so Utter can use the shortcut
    func quitLegacyApp() {
        NSRunningApplication.runningApplications(withBundleIdentifier: AppPaths.legacyBundleID).forEach { $0.terminate() }
    }

    // Navigation in the main window
    @Published var selectedPage: AppPage = .history
    /// Set by the app delegate; brings the main window to the front
    var showMainWindowHandler: (() -> Void)?

    // Overlay position persistence
    @AppStorage("overlayPositionX") var overlayPositionX: Double = -1
    @AppStorage("overlayPositionY") var overlayPositionY: Double = -1

    let audioEngine = AudioEngine()
    let transcriptionEngine = TranscriptionEngine()
    let pasteManager = PasteManager()
    let updateChecker = UpdateChecker()
    let history = HistoryStore()
    let vocabulary = VocabularyStore()
    let usage = UsageReporter()

    private var cancellables = Set<AnyCancellable>()

    init() {
        if !DocsMode.isOn {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                let ax = AXIsProcessTrusted()
                if mic != self.micGranted { self.micGranted = mic }
                if ax != self.accessibilityGranted { self.accessibilityGranted = ax }
                let legacy = AppState.isLegacyAppRunning()
                if legacy != self.legacyAppRunning { self.legacyAppRunning = legacy }
            }
        }
        }

        audioEngine.onLevel = { [weak self] level in
            guard let self else { return }
            self.levels = Array(self.levels.dropFirst()) + [level]
        }

        // Observe model ready state
        transcriptionEngine.$isModelReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isReady in
                if !isReady {
                    if self?.status == .idle { self?.status = .settingUp }
                    return
                }
                if isReady {
                    self?.status = .idle
                    // Hide overlay after setup complete
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self?.showOverlay = false
                    }
                }
            }
            .store(in: &cancellables)

        // Surface setup failures so the UI leaves the spinner and offers a retry
        transcriptionEngine.$setupFailed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] failed in
                guard let self else { return }
                if failed {
                    self.status = .setupFailed
                    self.showOverlay = true
                } else if self.status == .setupFailed {
                    self.status = .settingUp
                }
            }
            .store(in: &cancellables)

        // Views observe AppState; forward engine changes (progress, status text) so they redraw
        transcriptionEngine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        vocabulary.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        history.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        updateChecker.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// Cloud if chosen and set up, else on this Mac. Falls back to local if the cloud call fails.
    private func transcribe(_ audio: [Float]) async throws -> (String, String?) {
        let (raw, engine) = try await transcribeRaw(audio)
        return (vocabulary.apply(to: raw), engine)
    }

    private func transcribeRaw(_ audio: [Float]) async throws -> (String, String?) {
        if SpeechEngineKind.current == .cloud {
            if let cloud = CloudTranscriber.configured() {
                do {
                    return (try await cloud.transcribe(samples: audio), "Cloud · \(cloud.settings.hostLabel)")
                } catch {
                    cloudError = error.localizedDescription
                    print("Cloud transcription failed, using on-device model: \(error.localizedDescription)")
                }
            } else {
                cloudError = CloudTranscriptionError.notConfigured.localizedDescription
            }
        }
        return (try await transcriptionEngine.transcribe(audioBuffer: audio, hint: vocabulary.hintText), nil)
    }

    /// Esc / X on the indicator: stop listening and throw the audio away
    func cancelRecording() {
        guard status == .recording else { return }
        audioEngine.cancelRecording()
        recordingStartedAt = nil
        status = .idle
        showOverlay = false
    }

    /// Shows "Pasted" / "Copied" on the indicator for a moment
    private func showResult(_ result: DictationResult) {
        lastResult = result
        let hold: UInt64 = result == .pasted ? 1_200_000_000 : 3_000_000_000
        Task {
            try? await Task.sleep(nanoseconds: hold)
            if lastResult == result { lastResult = nil }
            if status == .idle { showOverlay = false }
        }
    }

    func completeOnboarding() {
        onboardingComplete = true
        objectWillChange.send()
    }

    func restartOnboarding() {
        onboardingComplete = false
        objectWillChange.send()
        showMainWindowHandler?()
    }

    func open(_ page: AppPage) {
        selectedPage = page
        showMainWindowHandler?()
    }

    /// Applies Light / Dark / System to every window, overlay included
    func applyAppearance() {
        switch AppearanceMode(rawValue: appearance) ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func copyLastDictation() {
        guard let last = history.entries.first else { return }
        pasteManager.copyToClipboard(last.text)
    }

    func retrySetup() {
        guard status == .setupFailed else { return }
        transcriptionEngine.retrySetup()
    }

    func toggleRecording() {
        switch status {
        case .settingUp:
            // Ignore while setting up
            break
        case .setupFailed:
            retrySetup()
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .transcribing:
            // Ignore while transcribing
            break
        }
    }

    func startRecording() {
        // Save the current frontmost app so we can paste back to it
        pasteManager.saveFrontmostApp()

        do {
            try audioEngine.startRecording()
            levels = Array(repeating: 0, count: levels.count)
            recordingStartedAt = Date()
            lastResult = nil
            status = .recording
            showOverlay = true

            if playSounds {
                NSSound(named: "Tink")?.play()
            }
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            showResult(.failed(micGranted ? "Microphone not available" : "Allow the microphone in Setup"))
        }
    }

    func stopRecording() {
        guard status == .recording else { return }

        status = .transcribing
        recordingStartedAt = nil

        if playSounds {
            NSSound(named: "Pop")?.play()
        }

        Task {
            do {
                let audioBuffer = try await audioEngine.stopRecording()
                let (text, engineLabel) = try await transcribe(audioBuffer)

                // Nothing heard: don't paste, and don't wipe what's on the clipboard
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    status = .idle
                    showResult(.failed("Didn't catch that"))
                    return
                }

                transcription = text

                // Paste text inline (copies to clipboard and pastes)
                let appName = pasteManager.targetAppName
                let pasted = pasteManager.pasteText(text)

                // Keep it in local history so it can be copied again
                history.add(text: text, appName: appName, pasted: pasted, engine: engineLabel)
                usage.dictationCompleted()

                status = .idle
                showResult(pasted ? .pasted : .copiedOnly)

            } catch {
                errorMessage = "Transcription failed: \(error.localizedDescription)"
                status = .idle
                showResult(.failed("Didn't catch that"))
            }
        }
    }

}
