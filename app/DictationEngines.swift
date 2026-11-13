import AVFoundation
import Foundation
import Speech
import WhisperKit

// VibeRemote Dictation's speech-to-text services. Every engine receives the same finished
// clip — 16 kHz mono float samples recorded from the VibeRemote input device while Siri was
// held — and returns plain text. One clip per hold keeps the engines interchangeable: the
// remote only streams audio while Siri is physically down, so there is never an open-ended
// session to stream partial results from.

/// Which service turns a Siri hold into text. Raw values are persisted.
enum DictationProvider: String, CaseIterable, Sendable {
    case apple, whisperKit, openAI, seedASR

    var title: String {
        switch self {
        case .apple: return "Apple (On Device)"
        case .whisperKit: return "WhisperKit (On Device)"
        case .openAI: return "OpenAI"
        case .seedASR: return "Seed ASR (ByteDance)"
        }
    }

    /// Cloud services need the user's own key; nothing is bundled or shared.
    var needsAPIKey: Bool { self == .openAI || self == .seedASR }
}

/// A recorded hold, resampled for speech recognition.
struct DictationAudio: Sendable {
    static let sampleRate: Double = 16_000
    var samples: [Float]

    var duration: TimeInterval { Double(samples.count) / Self.sampleRate }

    /// Root-mean-square level; a hold with the bridge stopped records digital silence.
    var rms: Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// 16-bit PCM WAV, the one container every cloud service here accepts.
    func wavData() -> Data {
        let rate = UInt32(Self.sampleRate)
        let dataSize = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + Int(dataSize))
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)) // PCM, mono
        append(rate); append(rate * 2)       // sample rate, byte rate
        append(UInt16(2)); append(UInt16(16)) // block align, bits per sample
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        for sample in samples {
            append(Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded()))
        }
        return data
    }

    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}

struct DictationError: LocalizedError, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The language the user speaks. Empty means automatic: the cloud services and Whisper
/// detect it; Apple's on-device model needs one, so it uses the Mac's own language.
enum DictationLanguage {
    static let choices: [(id: String, title: String)] = [
        ("", "Automatic"),
        ("en-US", "English"),
        ("zh-CN", "Chinese (Mandarin)"),
        ("yue-CN", "Cantonese"),
        ("ja-JP", "Japanese"),
        ("ko-KR", "Korean"),
        ("es-ES", "Spanish"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
    ]

    /// ISO 639-1 code for Whisper and OpenAI ("zh-CN" → "zh"). Whisper names Cantonese "yue".
    static func isoCode(_ identifier: String) -> String? {
        guard !identifier.isEmpty else { return nil }
        return identifier.split(separator: "-").first.map { String($0).lowercased() }
    }
}

protocol DictationEngine: Sendable {
    func transcribe(_ audio: DictationAudio, language: String) async throws -> String
}

// MARK: - Apple SpeechAnalyzer

/// macOS's own on-device recognizer. DictationTranscriber is the dictation-tuned module
/// (punctuation, short utterances); its language asset downloads on first use.
struct AppleDictationEngine: DictationEngine {
    func transcribe(_ audio: DictationAudio, language: String) async throws -> String {
        let requested = language.isEmpty ? Locale.current : Locale(identifier: language)
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) else {
            throw DictationError("Apple's on-device dictation does not support \(requested.identifier).")
        }
        let transcriber = DictationTranscriber(locale: locale, preset: .shortDictation)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            rmDebug("🗣 Downloading Apple speech assets for \(locale.identifier)")
            try await request.downloadAndInstall()
        }
        guard let source = audio.pcmBuffer() else { throw DictationError("Could not prepare the recording.") }
        let buffer: AVAudioPCMBuffer
        if let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
           target != source.format {
            buffer = try Self.convert(source, to: target)
        } else {
            buffer = source
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var text = ""
            for try await result in transcriber.results {
                text += String(result.text.characters)
            }
            return text
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
        do {
            try await analyzer.start(inputSequence: stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw DictationError("Could not convert the recording for Apple dictation.")
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw DictationError("Could not convert the recording for Apple dictation.")
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw conversionError ?? DictationError("Audio conversion failed.") }
        return output
    }
}

// MARK: - WhisperKit

/// Whisper models compiled for Core ML, downloaded once into Application Support.
enum WhisperModelCatalog {
    static let defaultModel = "openai_whisper-large-v3-v20240930_turbo"
    static let models: [(id: String, title: String)] = [
        ("openai_whisper-large-v3-v20240930_turbo", "Large v3 Turbo (best, ~1.6 GB)"),
        ("openai_whisper-large-v3-v20240930_626MB", "Large v3 Turbo, compressed (~630 MB)"),
        ("openai_whisper-small", "Small (~470 MB)"),
        ("openai_whisper-base", "Base (~140 MB)"),
    ]

    static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeRemote/WhisperKit", isDirectory: true)
    }

    private static let foldersKey = "dictationWhisperModelFolders"

    /// The folder a finished download landed in, if it is still on disk.
    static func installedFolder(for model: String) -> URL? {
        guard let path = (UserDefaults.standard.dictionary(forKey: foldersKey) as? [String: String])?[model],
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func recordInstalled(_ folder: URL, for model: String) {
        var folders = UserDefaults.standard.dictionary(forKey: foldersKey) as? [String: String] ?? [:]
        folders[model] = folder.path
        UserDefaults.standard.set(folders, forKey: foldersKey)
    }
}

/// Keeps one loaded Whisper pipeline: loading a large model takes seconds, a hold should not.
actor WhisperKitDictationEngine: DictationEngine {
    static let shared = WhisperKitDictationEngine()

    /// WhisperKit predates Sendable; this actor is its only user.
    private final class Pipeline: @unchecked Sendable {
        let kit: WhisperKit
        init(_ kit: WhisperKit) { self.kit = kit }
    }

    private var loaded: (model: String, pipeline: Pipeline)?
    private var preferredModel = WhisperModelCatalog.defaultModel

    func select(model: String) { preferredModel = model }

    /// Downloads (if needed) and loads the model, reporting download progress 0...1.
    func prepare(model: String, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        preferredModel = model
        if loaded?.model == model { return }
        let folder: URL
        if let installed = WhisperModelCatalog.installedFolder(for: model) {
            folder = installed
        } else {
            try FileManager.default.createDirectory(at: WhisperModelCatalog.downloadBase, withIntermediateDirectories: true)
            rmDebug("🗣 Downloading WhisperKit model \(model)")
            folder = try await WhisperKit.download(variant: model, downloadBase: WhisperModelCatalog.downloadBase) { value in
                progress?(value.fractionCompleted)
            }
            WhisperModelCatalog.recordInstalled(folder, for: model)
        }
        let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error,
                                      prewarm: false, load: true, download: false)
        loaded = (model, Pipeline(try await WhisperKit(config)))
    }

    func transcribe(_ audio: DictationAudio, language: String) async throws -> String {
        if loaded?.model != preferredModel { try await prepare(model: preferredModel) }
        guard let pipeline = loaded?.pipeline else { throw DictationError("The Whisper model is not loaded.") }
        let code = DictationLanguage.isoCode(language)
        let options = DecodingOptions(task: .transcribe, language: code, detectLanguage: code == nil,
                                      skipSpecialTokens: true, withoutTimestamps: true)
        let results = try await pipeline.kit.transcribe(audioArray: audio.samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }
}

// MARK: - OpenAI

struct OpenAIDictationEngine: DictationEngine {
    static let defaultModel = "gpt-4o-transcribe"
    static let models = ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    var apiKey: String
    var model: String
    /// The dictionary's vocabulary, as the endpoint's `prompt` (spellings it should prefer).
    var prompt: String? = nil

    /// Multipart form exactly as the transcription endpoint documents it.
    static func request(audio: DictationAudio, apiKey: String, model: String, language: String, prompt: String? = nil,
                        boundary: String = "VibeRemote-\(UUID().uuidString)") -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        if let code = DictationLanguage.isoCode(language) { field("language", code) }
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio.wavData())
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    static func parse(data: Data, status: Int) throws -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw DictationError("OpenAI: \(message ?? "HTTP \(status)")")
        }
        guard let text = json?["text"] as? String else { throw DictationError("OpenAI returned no text.") }
        return text
    }

    func transcribe(_ audio: DictationAudio, language: String) async throws -> String {
        let request = Self.request(audio: audio, apiKey: apiKey, model: model.isEmpty ? Self.defaultModel : model,
                                   language: language, prompt: prompt)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try Self.parse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

// MARK: - Seed ASR (ByteDance Volcengine)

/// Doubao's Seed-ASR big model through Volcengine's synchronous "flash" file-recognition
/// endpoint: one POST per clip, no submit/poll. The newer console issues one API key
/// (`X-Api-Key`); the older console issues an App ID plus Access Token. Both are supported.
struct SeedASRDictationEngine: DictationEngine {
    static let endpoint = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash")!
    static let defaultResourceID = "volc.bigasr.auc_turbo"
    static let successCode = "20000000"
    static let silenceCode = "20000003"

    var accessKey: String
    /// Empty for a new-console API key.
    var appID: String
    var resourceID: String = defaultResourceID
    /// The dictionary's hotwords (`request.corpus.context`). Volcengine documents this field for its
    /// streaming and standard recognizers, not explicitly for flash; see `AGENTS.md` for what the
    /// flash endpoint did with it.
    var context: String? = nil
    /// `enable_ddc` (语义顺滑): drop filler words, stutters and repeated phrases.
    var removeFillers = false
    /// `vad_segment_duration` in ms, as on the stream (`SeedStreamFrame.requestJSON`).
    var sentenceSilence: Int? = nil

    static func request(audio: DictationAudio, accessKey: String, appID: String, resourceID: String,
                        context: String? = nil, removeFillers: Bool = false, sentenceSilence: Int? = nil,
                        requestID: String = UUID().uuidString) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if appID.isEmpty {
            request.setValue(accessKey, forHTTPHeaderField: "X-Api-Key")
        } else {
            request.setValue(appID, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        }
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        var options: [String: Any] = ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true,
                                      "enable_ddc": removeFillers]
        if let context { options["corpus"] = ["context": context] }
        if let sentenceSilence { options["vad_segment_duration"] = sentenceSilence }
        let body: [String: Any] = [
            "user": ["uid": appID.isEmpty ? "viberemote" : appID],
            "audio": ["data": audio.wavData().base64EncodedString()],
            "request": options,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Volcengine reports the outcome in response headers, not the HTTP status alone.
    static func parse(data: Data, statusCode: String?, message: String?, httpStatus: Int) throws -> String {
        if statusCode == silenceCode { return "" }
        guard statusCode == successCode, (200..<300).contains(httpStatus) else {
            let detail = [statusCode, message].compactMap { $0 }.joined(separator: " ")
            throw DictationError("Seed ASR: \(detail.isEmpty ? "HTTP \(httpStatus)" : detail)")
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = (json?["result"] as? [String: Any])?["text"] as? String else {
            throw DictationError("Seed ASR returned no text.")
        }
        return text
    }

    func transcribe(_ audio: DictationAudio, language: String) async throws -> String {
        let request = Self.request(audio: audio, accessKey: accessKey, appID: appID,
                                   resourceID: resourceID.isEmpty ? Self.defaultResourceID : resourceID, context: context,
                                   removeFillers: removeFillers, sentenceSilence: sentenceSilence)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return try Self.parse(data: data,
                              statusCode: http?.value(forHTTPHeaderField: "X-Api-Status-Code"),
                              message: http?.value(forHTTPHeaderField: "X-Api-Message"),
                              httpStatus: http?.statusCode ?? 0)
    }
}
