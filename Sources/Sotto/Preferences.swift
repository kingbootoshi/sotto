import Foundation
import FluidAudio

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case fn
    case rightCommand
    case rightOption
    case rightControl

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: return "Hold Fn (globe)"
        case .rightCommand: return "Hold Right Command"
        case .rightOption: return "Hold Right Option"
        case .rightControl: return "Hold Right Control"
        }
    }

    var shortLabel: String {
        switch self {
        case .fn: return "fn"
        case .rightCommand: return "right \u{2318}"
        case .rightOption: return "right \u{2325}"
        case .rightControl: return "right \u{2303}"
        }
    }
}

final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    var hotkey: HotkeyChoice {
        get { HotkeyChoice(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .rightCommand }
        set { defaults.set(newValue.rawValue, forKey: "hotkey") }
    }

    /// false = Parakeet v2 (English, best recall), true = v3 (25 languages)
    var useMultilingualModel: Bool {
        get { defaults.bool(forKey: "useMultilingualModel") }
        set { defaults.set(newValue, forKey: "useMultilingualModel") }
    }

    var modelVersion: AsrModelVersion { useMultilingualModel ? .v3 : .v2 }

    var modelLabel: String { useMultilingualModel ? "Parakeet v3 (multilingual)" : "Parakeet v2 (English)" }

    var soundsEnabled: Bool {
        get { defaults.object(forKey: "soundsEnabled") == nil ? true : defaults.bool(forKey: "soundsEnabled") }
        set { defaults.set(newValue, forKey: "soundsEnabled") }
    }

    var soundPack: SoundPack {
        get { SoundPack(rawValue: defaults.string(forKey: "soundPack") ?? "") ?? .sotto }
        set { defaults.set(newValue.rawValue, forKey: "soundPack") }
    }
}

enum SottoError: LocalizedError {
    case modelsNotReady
    case noMicrophone
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .modelsNotReady: return "The speech model is still loading."
        case .noMicrophone: return "No microphone is available."
        case .microphoneDenied: return "Sotto needs microphone access. Enable it in System Settings, Privacy, Microphone."
        }
    }
}
