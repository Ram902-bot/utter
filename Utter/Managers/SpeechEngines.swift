import Foundation
import Security

// MARK: - Feature switch

/// 3.0 ships one on-device model (Whisper Small, English). The model picker and the
/// bring-your-own-key cloud engine stay in the code, hidden, until a real need shows up.
enum FeatureFlags {
    static let speechEngineChoice = false
}

// MARK: - Choices

/// Where speech is turned into text
enum SpeechEngineKind: String, CaseIterable, Identifiable {
    case local, cloud
    var id: String { rawValue }
    var label: String { self == .local ? "On this Mac" : "Cloud (your API key)" }

    static let defaultsKey = "speechEngine"
    static var current: SpeechEngineKind {
        guard FeatureFlags.speechEngineChoice else { return .local }
        return SpeechEngineKind(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .local
    }
}

/// On-device Whisper models (Core ML builds from argmaxinc/whisperkit-coreml)
enum LocalModel: String, CaseIterable, Identifiable {
    case baseEn = "openai_whisper-base.en"
    case smallEn = "openai_whisper-small.en"
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .baseEn: return "Fast (English)"
        case .smallEn: return "Balanced (English)"
        case .largeV3Turbo: return "Accurate (multilingual)"
        }
    }

    var detail: String {
        switch self {
        case .baseEn: return "Whisper Base, 147 MB. Quickest, less accurate."
        case .smallEn: return "Whisper Small, 487 MB. The default."
        case .largeV3Turbo: return "Whisper Large v3 Turbo, 646 MB. Best accuracy, 99 languages, slower on older Macs."
        }
    }

    /// Hugging Face repo WhisperKit looks for the tokenizer under
    var tokenizer: String {
        switch self {
        case .baseEn: return "openai/whisper-base.en"
        case .smallEn: return "openai/whisper-small.en"
        case .largeV3Turbo: return "openai/whisper-large-v3"
        }
    }

    static let defaultsKey = "localModel"
    static var current: LocalModel {
        guard FeatureFlags.speechEngineChoice else { return .smallEn }
        return LocalModel(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .smallEn
    }
}

/// OpenAI-compatible speech-to-text services (POST {baseURL}/audio/transcriptions)
enum CloudProvider: String, CaseIterable, Identifiable {
    case openai, groq, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .openai: return "OpenAI"
        case .groq: return "Groq"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: return "whisper-1"
        case .groq: return "whisper-large-v3-turbo"
        case .custom: return ""
        }
    }

    static let defaultsKey = "cloudProvider"
    static var current: CloudProvider {
        CloudProvider(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .openai
    }
}

/// What the user configured for the cloud engine
struct CloudSettings {
    var provider: CloudProvider
    var baseURL: String
    var model: String

    static let baseURLKey = "cloudBaseURL"
    static let modelKey = "cloudModel"

    static func load() -> CloudSettings {
        let provider = CloudProvider.current
        let d = UserDefaults.standard
        let url = d.string(forKey: baseURLKey).flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultBaseURL
        let model = d.string(forKey: modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultModel
        return CloudSettings(provider: provider, baseURL: url, model: model)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(provider.rawValue, forKey: CloudProvider.defaultsKey)
        d.set(baseURL, forKey: Self.baseURLKey)
        d.set(model, forKey: Self.modelKey)
    }

    /// Short name for labels ("api.openai.com")
    var hostLabel: String {
        URL(string: baseURL)?.host ?? provider.label
    }
}

// MARK: - Keychain

/// API keys live in the macOS Keychain, never in settings files
enum KeychainStore {
    private static let service = "com.ram902.utter.cloud"

    static func save(_ key: String, account: String) -> Bool {
        delete(account: account)
        guard !key.isEmpty, let data = key.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}

// MARK: - Cloud transcription

enum CloudTranscriptionError: LocalizedError {
    case notConfigured
    case badResponse(Int, String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cloud engine isn't set up. Add a URL, model and API key in Settings."
        case .badResponse(let code, let message): return "The service answered \(code): \(message)"
        case .network(let message): return message
        }
    }
}

/// Sends 16 kHz mono audio as a WAV file to an OpenAI-compatible transcription endpoint
struct CloudTranscriber {
    let settings: CloudSettings
    let apiKey: String

    static func configured() -> CloudTranscriber? {
        let settings = CloudSettings.load()
        guard let key = KeychainStore.read(account: settings.provider.rawValue), !key.isEmpty,
              URL(string: settings.baseURL)?.scheme == "https", !settings.model.isEmpty else { return nil }
        return CloudTranscriber(settings: settings, apiKey: key)
    }

    func transcribe(samples: [Float], sampleRate: Int = 16_000) async throws -> String {
        guard let url = URL(string: settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/audio/transcriptions") else {
            throw CloudTranscriptionError.notConfigured
        }
        let boundary = "utter-\(UUID().uuidString)"
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", settings.model)
        field("response_format", "json")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(Self.wav(from: samples, sampleRate: sampleRate))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CloudTranscriptionError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "request failed"
            throw CloudTranscriptionError.badResponse(status, message)
        }
        struct Reply: Decodable { let text: String }
        return try JSONDecoder().decode(Reply.self, from: data).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 16-bit PCM WAV
    static func wav(from samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var header = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        header.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        header.append("data".data(using: .ascii)!); u32(UInt32(pcm.count))
        return header + pcm
    }
}
