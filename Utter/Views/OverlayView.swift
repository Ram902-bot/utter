import SwiftUI

/// Floating indicator: a thin line when idle, a live pill while dictating,
/// and a short "Pasted" / "Copied" confirmation afterwards.
struct OverlayView: View {
    @EnvironmentObject var appState: AppState
    @State private var isHovering = false
    @State private var didDrag = false
    var onTap: (() -> Void)?

    private enum Mode: Equatable {
        case line, hover, setup, setupFailed, recording, transcribing, result(DictationResult)
    }

    private var mode: Mode {
        switch appState.status {
        case .settingUp: return .setup
        case .setupFailed: return .setupFailed
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .idle:
            if let result = appState.lastResult { return .result(result) }
            if appState.transcriptionEngine.isDownloading { return .setup }
            return isHovering ? .hover : .line
        }
    }

    var body: some View {
        ZStack {
            Capsule()
                .fill(mode == .line ? AnyShapeStyle(Color.gray.opacity(0.55)) : AnyShapeStyle(Material.regularMaterial))
                .overlay(Capsule().strokeBorder(borderColor, lineWidth: mode == .line ? 0 : 1))
                .shadow(color: .black.opacity(mode == .line ? 0 : 0.18), radius: 10, y: 3)

            content
                .padding(.horizontal, 12)
        }
        .frame(width: pillWidth, height: pillHeight)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: mode)
        .contentShape(Capsule())
        .onHover { hovering in isHovering = hovering }
        .simultaneousGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in didDrag = true }
                .onEnded { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { didDrag = false }
                }
        )
        .onTapGesture {
            guard !didDrag else { return }
            if case .result(.copiedOnly) = mode {
                appState.open(.history)
            } else {
                onTap?()
            }
        }
        .help(helpText)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .line:
            EmptyView()
        case .hover:
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        case .setup:
            HStack(spacing: 8) {
                if appState.transcriptionEngine.isDownloading && appState.transcriptionEngine.downloadProgress < 1.0 {
                    DownloadProgressView(progress: appState.transcriptionEngine.downloadProgress)
                    label("Downloading \(Int(appState.transcriptionEngine.downloadProgress * 100))%")
                } else {
                    ProgressView().controlSize(.mini)
                    label(appState.transcriptionEngine.setupStatus.isEmpty ? "Setting up..." : appState.transcriptionEngine.setupStatus)
                }
            }
        case .setupFailed:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                label("Setup failed - click to retry")
            }
        case .recording:
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .modifier(PulseAnimation())
                LevelBars(levels: appState.levels)
                if SpeechEngineKind.current == .cloud {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("Audio will be sent to your cloud provider")
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsed(at: context.date))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Button {
                    appState.cancelRecording()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("Cancel - throw this recording away")
                .accessibilityLabel("Cancel recording")
            }
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                label("Transcribing...")
            }
        case .result(let result):
            HStack(spacing: 6) {
                switch result {
                case .pasted:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    label("Pasted")
                case .copiedOnly:
                    Image(systemName: "doc.on.clipboard.fill").foregroundColor(.orange)
                    label("Copied - press Cmd+V")
                case .failed(let message):
                    Image(systemName: "exclamationmark.circle.fill").foregroundColor(.secondary)
                    label(message)
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    private func elapsed(at date: Date) -> String {
        let seconds = Int(date.timeIntervalSince(appState.recordingStartedAt ?? date))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var borderColor: Color {
        mode == .recording ? Color.red.opacity(0.45) : Color.primary.opacity(0.12)
    }

    private var helpText: String {
        switch mode {
        case .recording: return "Click to stop, or press Cmd+Shift+Space"
        case .result(.copiedOnly): return "Paste didn't work. The text is on your clipboard. Click to open History."
        case .hover: return "Click to dictate"
        default: return ""
        }
    }

    private var pillWidth: CGFloat {
        switch mode {
        case .line: return 40
        case .hover: return 44
        case .setup: return 210
        case .setupFailed: return 220
        case .recording: return SpeechEngineKind.current == .cloud ? 214 : 196
        case .transcribing: return 140
        case .result(.pasted): return 104
        case .result: return 196
        }
    }

    private var pillHeight: CGFloat {
        switch mode {
        case .line: return 5
        case .hover: return 26
        default: return 34
        }
    }
}

/// Live mic level, newest sample on the right
struct LevelBars: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: 3, height: 3 + CGFloat(level) * 15)
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

// Download progress bar
struct DownloadProgressView: View {
    let progress: Double

    var body: some View {
        ZStack(alignment: .leading) {
            // Background track
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.2))
                .frame(width: 50, height: 4)

            // Progress fill
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: max(4, 50 * progress), height: 4)
                .animation(.easeInOut(duration: 0.2), value: progress)
        }
    }
}

// Pulse animation modifier
struct PulseAnimation: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.2 : 1.0)
            .opacity(isPulsing ? 0.7 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

// Bouncing dot animation for loader
struct BouncingDot: ViewModifier {
    let delay: Double
    @State private var isAnimating = false

    func body(content: Content) -> some View {
        content
            .offset(y: isAnimating ? -4 : 2)
            .animation(
                .easeInOut(duration: 0.4)
                .repeatForever(autoreverses: true)
                .delay(delay),
                value: isAnimating
            )
            .onAppear {
                isAnimating = true
            }
    }
}

// Overlay window controller - draggable, position persisted
class OverlayWindowController: NSWindowController, NSWindowDelegate {
    private var appState: AppState?

    convenience init(appState: AppState) {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver  // Stay above Dock and desktop icons
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = true  // Allow dragging to reposition
        window.hasShadow = false
        window.appearance = NSAppearance(named: .darkAqua)  // Indicator stays dark in Light mode too

        self.init(window: window)
        self.appState = appState
        window.delegate = self

        let hostingView = NSHostingView(rootView:
            OverlayView(onTap: { [weak self] in
                self?.appState?.toggleRecording()
            })
            .environmentObject(appState)
            .environment(\.colorScheme, .dark)
        )
        window.contentView = hostingView

        restorePosition()
    }

    func windowDidMove(_ notification: Notification) {
        savePosition()
    }

    private func savePosition() {
        guard let window = window, let appState = appState else { return }
        let origin = window.frame.origin
        appState.overlayPositionX = origin.x
        appState.overlayPositionY = origin.y
    }

    private func restorePosition() {
        guard let appState = appState else {
            positionAtBottomCenter()
            return
        }

        // If no saved position, use default
        if appState.overlayPositionX < 0 || appState.overlayPositionY < 0 {
            positionAtBottomCenter()
            return
        }

        // Restore saved position
        window?.setFrameOrigin(NSPoint(x: appState.overlayPositionX, y: appState.overlayPositionY))
    }

    func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        guard let window = window else { return }

        // Calculate exact center of screen
        let windowWidth: CGFloat = 240
        let x = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
        let y = screenFrame.origin.y + 20  // 20px from bottom

        window.setFrameOrigin(NSPoint(x: x, y: y))
        savePosition()
    }

    func resetPosition() {
        positionAtBottomCenter()
    }

    func show() {
        restorePosition()
        window?.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }
}
