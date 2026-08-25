import Foundation

enum SpeechBackendKind: Equatable {
    case whisperKit
    case fluidAudio
    case speechAnalyzer
}

enum FluidAudioModelVariant: Equatable {
    case parakeetV3
    case qwen3AsrInt8
}

struct SpeechModelDescriptor: Identifiable, Equatable {
    let name: String
    let pickerTitle: String
    let variantName: String
    let sizeDescription: String
    let backend: SpeechBackendKind
    let cachePathComponents: [String]
    let fluidAudioVariant: FluidAudioModelVariant?

    var id: String { name }

    var pickerLabel: String {
        "\(pickerTitle) (\(variantName) - \(sizeDescription))"
    }

    var statusName: String {
        switch backend {
        case .whisperKit:
            "Whisper \(variantName) (\(pickerTitle.lowercased()))"
        case .fluidAudio:
            "\(pickerTitle) (\(variantName.lowercased()))"
        case .speechAnalyzer:
            pickerTitle
        }
    }

    var supportsSpeakerFiltering: Bool {
        // Speaker filtering uses a separate diarization pipeline, so any
        // FluidAudio-backed ASR model can participate in filtering.
        backend == .fluidAudio
    }

    var isSystemManaged: Bool {
        backend == .speechAnalyzer
    }

    var automaticLanguageLabel: String {
        isSystemManaged ? "System language" : "Auto-detect"
    }
}

enum SpeechModelCatalog {
    static let whisperTiny = SpeechModelDescriptor(
        name: "openai_whisper-tiny.en",
        pickerTitle: "Speed",
        variantName: "tiny.en",
        sizeDescription: "~75 MB",
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-tiny.en"],
        fluidAudioVariant: nil
    )

    static let whisperSmallEnglish = SpeechModelDescriptor(
        name: "openai_whisper-small.en",
        pickerTitle: "Accuracy",
        variantName: "small.en",
        sizeDescription: "~466 MB",
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-small.en"],
        fluidAudioVariant: nil
    )

    static let whisperSmallMultilingual = SpeechModelDescriptor(
        name: "openai_whisper-small",
        pickerTitle: "Multilingual",
        variantName: "small",
        sizeDescription: "~466 MB",
        backend: .whisperKit,
        cachePathComponents: ["openai", "whisper-small"],
        fluidAudioVariant: nil
    )

    /// AF Flow's default. Multilingual, and the reason it is the default is
    /// measured rather than assumed: 27 percent of Andrew's real dictation is
    /// Russian, and the fork shipped an English-only default that would have
    /// produced confident nonsense for every one of those utterances rather
    /// than an error.
    static let whisperLargeV3Turbo = SpeechModelDescriptor(
        name: "openai_whisper-large-v3-v20240930_turbo_632MB",
        pickerTitle: "Recommended",
        variantName: "large-v3-turbo",
        sizeDescription: "~632 MB",
        backend: .whisperKit,
        cachePathComponents: ["argmaxinc", "whisperkit-coreml", "openai_whisper-large-v3-v20240930_turbo_632MB"],
        fluidAudioVariant: nil
    )

    /// Accuracy fallback if turbo disappoints on Russian, per the product spec.
    /// Same family, larger weights, no new plumbing.
    static let whisperLargeV3TurboLarge = SpeechModelDescriptor(
        name: "openai_whisper-large-v3_turbo_954MB",
        pickerTitle: "Highest accuracy",
        variantName: "large-v3-turbo, larger",
        sizeDescription: "~954 MB",
        backend: .whisperKit,
        cachePathComponents: ["argmaxinc", "whisperkit-coreml", "openai_whisper-large-v3_turbo_954MB"],
        fluidAudioVariant: nil
    )

    static let parakeetV3 = SpeechModelDescriptor(
        name: "fluid_parakeet-v3",
        pickerTitle: "Parakeet v3",
        variantName: "25 languages",
        sizeDescription: "~1.4 GB",
        backend: .fluidAudio,
        cachePathComponents: ["FluidInference", "parakeet-tdt-0.6b-v3-coreml"],
        fluidAudioVariant: .parakeetV3
    )

    static let qwen3AsrInt8 = SpeechModelDescriptor(
        name: "fluid_qwen3-asr-0.6b-int8",
        pickerTitle: "Qwen3-ASR 0.6B",
        variantName: "int8, 50+ languages",
        sizeDescription: "~900 MB",
        backend: .fluidAudio,
        cachePathComponents: [],
        fluidAudioVariant: .qwen3AsrInt8
    )

    static let speechAnalyzer = SpeechModelDescriptor(
        name: "apple_speech-analyzer",
        pickerTitle: "Apple SpeechAnalyzer",
        variantName: "System model",
        sizeDescription: "Managed by macOS",
        backend: .speechAnalyzer,
        cachePathComponents: [],
        fluidAudioVariant: nil
    )

    /// Models that are always selectable on the current OS.
    private static let baseModels: [SpeechModelDescriptor] = [
        whisperLargeV3Turbo,
        whisperLargeV3TurboLarge,
        whisperTiny,
        whisperSmallEnglish,
        whisperSmallMultilingual,
        parakeetV3,
    ]

    static var availableModels: [SpeechModelDescriptor] {
        var models = baseModels
        if #available(macOS 15, iOS 18, *) {
            models.append(qwen3AsrInt8)
        }
        if #available(macOS 26, *) {
            models.append(speechAnalyzer)
        }
        return models
    }

    /// Changed from `whisperSmallEnglish` on 2026-07-19. The fork's default was
    /// English-only, so a fresh install silently failed roughly a quarter of
    /// Andrew's real dictation instead of reporting an error.
    static let defaultModelID = whisperLargeV3Turbo.id

    static var whisperModels: [SpeechModelDescriptor] {
        availableModels.filter { $0.backend == .whisperKit }
    }

    /// What the home screen shows as the model in use.
    ///
    /// Resolved through the same `speechModel` key `@AppStorage` reads, with
    /// the same absent-means-default rule, so the front door cannot claim one
    /// model while the engine runs another. Falls back to the variant name
    /// rather than the picker title, because "Recommended" tells a viewer
    /// nothing and "large-v3-turbo" tells them what it is.
    static var currentDisplayName: String {
        let stored = UserDefaults.standard.string(forKey: "speechModel")
        let name = stored ?? defaultModelID
        guard let descriptor = model(named: name) ?? model(named: defaultModelID) else {
            return "unknown model"
        }
        return descriptor.variantName
    }

    static func model(named name: String) -> SpeechModelDescriptor? {
        availableModels.first { $0.name == name }
    }
}
