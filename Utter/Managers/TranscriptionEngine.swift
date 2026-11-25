import Foundation
import WhisperKit

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(String)
    case modelDownloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Model not loaded"
        case .transcriptionFailed(let reason): return "Transcription failed: \(reason)"
        case .modelDownloadFailed(let reason): return "Model download failed: \(reason)"
        }
    }
}

/// Downloads WhisperKit model files straight from Hugging Face with patient timeouts.
/// Files land at the same paths WhisperKit's Hub downloader uses, so existing installs
/// are reused. Each file is staged and moved into place only once fully downloaded,
/// so a file on disk with the expected size is always complete.
final class ModelDownloader {
    private struct RemoteEntry: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    private struct RemoteFile {
        let repo: String
        let path: String
        let size: Int64?
        let destination: URL
    }

    private let session: URLSession
    private let maxAttempts: Int
    private let endpoint = "https://huggingface.co"
    private let modelRepo = "argmaxinc/whisperkit-coreml"
    private let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json", "config.json"]

    init(maxAttempts: Int) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180     // Allow long gaps while a proxy scans the file
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        self.maxAttempts = maxAttempts
    }

    /// Returns the local model folder once every file is downloaded.
    func downloadModel(
        variant: String,
        tokenizer: String,
        to modelDir: URL,
        progress: @escaping (Double) -> Void,
        onRetry: @escaping (Int, Int) -> Void
    ) async throws -> URL {
        let hubRoot = modelDir.appendingPathComponent("models")
        let modelFolder = hubRoot.appendingPathComponent(modelRepo).appendingPathComponent(variant)

        let entries = try await withRetries(onRetry: onRetry) {
            try await self.listFiles(in: variant)
        }
        var files = entries.map {
            RemoteFile(repo: modelRepo, path: $0.path, size: $0.size,
                       destination: hubRoot.appendingPathComponent(modelRepo).appendingPathComponent($0.path))
        }
        files += tokenizerFiles.map {
            RemoteFile(repo: tokenizer, path: $0, size: nil,
                       destination: hubRoot.appendingPathComponent(tokenizer).appendingPathComponent($0))
        }

        let totalBytes = max(files.compactMap(\.size).reduce(0, +), 1)
        var completedBytes: Int64 = 0
        for file in files where isComplete(file) {
            completedBytes += file.size ?? 0
        }
        progress(Double(completedBytes) / Double(totalBytes))

        for file in files where !isComplete(file) {
            let base = completedBytes
            // Resumes after every drop (corporate proxies cut long downloads at random points).
            // Keeps retrying while attempts make progress; gives up after maxAttempts in a row with none.
            var stalledAttempts = 0
            var attempt = 0
            while true {
                attempt += 1
                let before = partialSize(of: file)
                do {
                    try await self.downloadFile(file) { bytesSoFar in
                        progress(min(Double(base + bytesSoFar) / Double(totalBytes), 1.0))
                    }
                    break
                } catch {
                    stalledAttempts = partialSize(of: file) > before ? 0 : stalledAttempts + 1
                    print("Model download attempt \(attempt) for \(file.path) stopped: \(error.localizedDescription)")
                    if stalledAttempts >= maxAttempts { throw error }
                    onRetry(attempt + 1, maxAttempts)
                    try? await Task.sleep(nanoseconds: UInt64(min(stalledAttempts + 1, 5)) * 2_000_000_000)
                }
            }
            completedBytes += file.size ?? 0
        }

        progress(1.0)
        return modelFolder
    }

    private func withRetries<T>(onRetry: (Int, Int) -> Void, _ operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                print("Model download attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < maxAttempts {
                    onRetry(attempt + 1, maxAttempts)
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
                }
            }
        }
        throw lastError ?? TranscriptionError.modelDownloadFailed("Unknown error")
    }

    private func listFiles(in variant: String) async throws -> [RemoteEntry] {
        let url = URL(string: "\(endpoint)/api/models/\(modelRepo)/tree/main/\(variant)?recursive=true")!
        let (data, response) = try await session.data(from: url)
        try checkStatus(response, for: variant)
        let files = try JSONDecoder().decode([RemoteEntry].self, from: data).filter { $0.type == "file" }
        guard !files.isEmpty else {
            throw TranscriptionError.modelDownloadFailed("No model files found for \(variant)")
        }
        return files
    }

    private func isComplete(_ file: RemoteFile) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.destination.path),
              let size = attrs[.size] as? Int64 else { return false }
        if let expected = file.size { return size == expected }
        return size > 0
    }

    /// Partial download kept next to the destination, so retries (and app restarts) resume it
    private func partURL(_ file: RemoteFile) -> URL {
        file.destination.appendingPathExtension("part")
    }

    private func partialSize(of file: RemoteFile) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: partURL(file).path))?[.size] as? Int64 ?? 0
    }

    /// Downloads one file, resuming from any partial data with an HTTP Range request.
    /// onBytes reports the bytes of this file on disk so far (including resumed data).
    private func downloadFile(_ file: RemoteFile, onBytes: @escaping (Int64) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = partURL(file)
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }

        let url = URL(string: "\(endpoint)/\(file.repo)/resolve/main/\(file.path)")!
        let task = RangeDownload(url: url, part: part, expected: file.size, onBytes: onBytes)
        try await task.run(configuration: session.configuration)

        let size = (try? fm.attributesOfItem(atPath: part.path))?[.size] as? Int64 ?? 0
        if let expected = file.size, size != expected {
            if size > expected { try? fm.removeItem(at: part) }
            throw TranscriptionError.modelDownloadFailed("\(file.path) is \(size) bytes, expected \(expected)")
        }
        if fm.fileExists(atPath: file.destination.path) {
            try fm.removeItem(at: file.destination)
        }
        try fm.moveItem(at: part, to: file.destination)
    }

    private func checkStatus(_ response: URLResponse?, for name: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw TranscriptionError.modelDownloadFailed("HTTP \(http.statusCode) for \(name)")
        }
    }
}

/// One HTTP download that appends to a partial file, asking the server only for the missing bytes
private final class RangeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let part: URL
    private let expected: Int64?
    private let onBytes: (Int64) -> Void
    private var handle: FileHandle?
    private var onDisk: Int64 = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(url: URL, part: URL, expected: Int64?, onBytes: @escaping (Int64) -> Void) {
        self.url = url
        self.part = part
        self.expected = expected
        self.onBytes = onBytes
    }

    func run(configuration: URLSessionConfiguration) async throws {
        onDisk = (try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int64 ?? 0
        if let expected, onDisk == expected { return }
        if let expected, onDisk > expected {
            try? FileManager.default.removeItem(at: part)
            FileManager.default.createFile(atPath: part.path, contents: nil)
            onDisk = 0
        }
        var request = URLRequest(url: url)
        if onDisk > 0 { request.setValue("bytes=\(onDisk)-", forHTTPHeaderField: "Range") }

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            switch status {
            case 206:
                break // server sent only the missing bytes: append
            case 200:
                // Server ignored the range and sent the whole file: start the partial file over
                try Data().write(to: part)
                onDisk = 0
            default:
                throw TranscriptionError.modelDownloadFailed("HTTP \(status) for \(url.lastPathComponent)")
            }
            let handle = try FileHandle(forWritingTo: part)
            try handle.seekToEnd()
            self.handle = handle
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            onDisk += Int64(data.count)
            onBytes(onDisk)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if let error = failure ?? error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}

@MainActor
class TranscriptionEngine: ObservableObject {
    private var whisperKit: WhisperKit?
    private var isLoading = false

    @Published var isModelReady = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var setupStatus: String = ""
    @Published var setupFailed = false
    @Published var setupError: String?
    @Published private(set) var activeModel: LocalModel = LocalModel.current

    private static let maxDownloadAttempts = 4
    private var modelDir: URL { AppPaths.supportDirectory.appendingPathComponent("models") }

    private func folder(for model: LocalModel) -> URL {
        modelDir.appendingPathComponent("models/argmaxinc/whisperkit-coreml").appendingPathComponent(model.rawValue)
    }

    /// True when this model is fully on disk
    func isDownloaded(_ model: LocalModel) -> Bool {
        isModelComplete(at: folder(for: model))
    }

    /// Switch on-device model; downloads it if needed
    func switchModel(to model: LocalModel) {
        guard model != activeModel || !isModelReady else { return }
        UserDefaults.standard.set(model.rawValue, forKey: LocalModel.defaultsKey)
        activeModel = model
        whisperKit = nil
        isModelReady = false
        Task { await loadModel() }
    }

    /// Deletes downloaded models other than the active one. Returns MB freed.
    @discardableResult
    func removeUnusedModels() -> Int {
        var freed: Int64 = 0
        for model in LocalModel.allCases where model != activeModel {
            let url = folder(for: model)
            if let size = Self.directorySize(url) { freed += size }
            try? FileManager.default.removeItem(at: url)
        }
        objectWillChange.send()
        return Int(freed / 1_000_000)
    }

    private static func directorySize(_ url: URL) -> Int64? {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var total: Int64 = 0
        for case let file as URL in e {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
    private static let requiredModelParts = ["AudioEncoder", "MelSpectrogram", "TextDecoder"]

    init() {
        if DocsMode.isOn {
            isModelReady = true
            return
        }
        Task {
            await loadModel()
        }
    }

    /// Retry setup after a failure. Partial downloads are kept so they resume.
    func retrySetup() {
        guard !isLoading, !isModelReady else { return }
        Task {
            await loadModel()
        }
    }

    private func loadModel() async {
        guard !isLoading else { return }
        isLoading = true
        setupFailed = false
        setupError = nil
        setupStatus = "Setting up Utter..."

        do {
            // Download model to Application Support (persists across app updates)
            let modelDir = self.modelDir
            let model = activeModel

            // Create directory if needed
            try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

            // Only reuse a model whose parts are all fully downloaded. A partial
            // download fails to load, so it falls through to download, which resumes it.
            let modelFolder: URL
            let existing = folder(for: model)
            if isModelComplete(at: existing) {
                modelFolder = existing
            } else {
                modelFolder = try await downloadModel(model, to: modelDir)
            }

            isDownloading = false
            downloadProgress = 1.0
            setupStatus = "Optimizing for your Mac..."

            whisperKit = try await WhisperKit(
                downloadBase: modelDir,
                modelFolder: modelFolder.path,
                verbose: false,
                logLevel: .none,
                load: true
            )

            // A different model was picked while this one loaded
            guard model == activeModel else {
                isLoading = false
                await loadModel()
                return
            }

            setupStatus = "Ready!"
            isModelReady = true
            print("WhisperKit model loaded successfully")

        } catch {
            isDownloading = false
            setupStatus = "Setup failed - click to retry"
            setupError = error.localizedDescription
            setupFailed = true
            print("Failed to load WhisperKit model: \(error)")
        }

        isLoading = false
    }

    /// Download the model and tokenizer with our own downloader. WhisperKit's bundled
    /// Hub downloader aborts after 10s without data, which proxies that scan large
    /// files (e.g. Netskope) routinely exceed, so the download never completes.
    private func downloadModel(_ model: LocalModel, to modelDir: URL) async throws -> URL {
        isDownloading = true
        downloadProgress = 0.0
        setupStatus = "Downloading AI model..."

        let downloader = ModelDownloader(maxAttempts: Self.maxDownloadAttempts)
        let folder = try await downloader.downloadModel(
            variant: model.rawValue,
            tokenizer: model.tokenizer,
            to: modelDir
        ) { [weak self] fraction in
            Task { @MainActor in
                self?.downloadProgress = fraction
            }
        } onRetry: { [weak self] attempt, max in
            Task { @MainActor in
                self?.setupStatus = "Retrying download (\(attempt)/\(max))..."
            }
        }

        guard isModelComplete(at: folder) else {
            throw TranscriptionError.modelDownloadFailed("Model files incomplete after download")
        }
        return folder
    }

    /// True only when every CoreML part has its compiled data and weights on disk.
    private func isModelComplete(at folder: URL) -> Bool {
        let fileManager = FileManager.default
        for part in Self.requiredModelParts {
            let partDir = folder.appendingPathComponent("\(part).mlmodelc")
            let coremlData = partDir.appendingPathComponent("coremldata.bin").path
            let weights = partDir.appendingPathComponent("weights/weight.bin").path
            guard fileManager.fileExists(atPath: coremlData),
                  let attrs = try? fileManager.attributesOfItem(atPath: weights),
                  let size = attrs[.size] as? Int, size > 0 else {
                return false
            }
        }
        return true
    }

    /// - Parameter hint: the user's vocabulary, passed to Whisper as a prompt so it spells those words right
    func transcribe(audioBuffer: [Float], hint: String? = nil) async throws -> String {
        if whisperKit == nil { await loadModel() }
        guard let whisperKit = self.whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }
        return try await performTranscription(whisperKit: whisperKit, audioBuffer: audioBuffer, hint: hint)
    }

    /// Whisper's prompt window is ~223 tokens; stay under it
    private static let maxHintTokens = 200

    private func performTranscription(whisperKit: WhisperKit, audioBuffer: [Float], hint: String?) async throws -> String {
        var options = DecodingOptions()
        // Skip the hint on very short clips: with almost no audio, Whisper may "say" listed words
        if let hint, audioBuffer.count >= 16_000, let tokenizer = whisperKit.tokenizer {
            let tokens = tokenizer.encode(text: hint).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            options.promptTokens = Array(tokens.prefix(Self.maxHintTokens))
        }
        let results = try await whisperKit.transcribe(audioArray: audioBuffer, decodeOptions: options)

        guard let result = results.first else {
            throw TranscriptionError.transcriptionFailed("No transcription result")
        }

        // Clean up the text
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove common Whisper artifacts
        let artifacts = [
            "[BLANK_AUDIO]",
            "[BLANK AUDIO]",
            "(silence)",
            "[ Pause ]",
            "[Pause]",
            "(pause)",
            "[Music]",
            "[MUSIC]",
            "(music)",
            "[Applause]",
            "[APPLAUSE]",
            "(applause)",
            "[Laughter]",
            "[LAUGHTER]",
            "(laughter)",
            "...",
            "[ Silence ]",
            "[Silence]"
        ]

        for artifact in artifacts {
            text = text.replacingOccurrences(of: artifact, with: "", options: .caseInsensitive)
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // If only artifacts were detected, return empty
        if text.isEmpty {
            return ""
        }

        // Remove common hallucinations (Whisper trained on YouTube)
        let hallucinations = [
            "thank you for watching",
            "thanks for watching",
            "please subscribe",
            "like and subscribe",
            "subtitles by the amara.org community",
            "subtitles by the amara org community",
            "satsang with mooji",
            "transcribed by https://otter.ai",
            "www.mooji.org"
        ]

        let lowerText = text.lowercased()
        for hallucination in hallucinations {
            if lowerText == hallucination || lowerText.hasPrefix(hallucination + ".") || lowerText.hasPrefix(hallucination + "!") {
                return ""
            }
        }

        // With a hint, silence can come back as the word list itself: drop that
        if let hint, Self.isEchoOfHint(text, hint: hint) {
            return ""
        }

        // Fix common homophones
        text = fixHomophones(text)

        return text
    }

    /// True when every word is from the hint and it reads like a list, i.e. Whisper repeated the prompt
    static func isEchoOfHint(_ text: String, hint: String) -> Bool {
        let words: (String) -> [String] = { $0.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty } }
        let hintWords = Set(words(hint))
        let textWords = words(text)
        return textWords.count >= 3 && text.filter({ $0 == "," }).count >= 2 && textWords.allSatisfy(hintWords.contains)
    }

    private func fixHomophones(_ text: String) -> String {
        var result = text

        // "High" at start of sentence or after punctuation → "Hi"
        // Matches: "High," "High!" "High." or "High " at start
        let patterns: [(pattern: String, replacement: String)] = [
            ("^High,", "Hi,"),
            ("^High!", "Hi!"),
            ("^High\\.", "Hi."),
            ("^High ", "Hi "),
            ("\\. High,", ". Hi,"),
            ("\\. High ", ". Hi "),
            ("! High,", "! Hi,"),
            ("! High ", "! Hi "),
            ("\\? High,", "? Hi,"),
            ("\\? High ", "? Hi ")
        ]

        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: replacement
                )
            }
        }

        return result
    }
}
