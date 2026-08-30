import AVFoundation
import Foundation

enum SoundCue: CaseIterable {
    case ack, merge, charge, launch, arrive
}

enum SoundPack: String, CaseIterable, Identifiable {
    case sotto, velvetThud, warmGlass, woodBar, breath, heartbeat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sotto: return "Sotto — the certified set (F/C, wood + felt + swell)"
        case .velvetThud: return "Velvet Thud — sub pulses you feel"
        case .warmGlass: return "Warm Glass — muted mallet tones"
        case .woodBar: return "Wood Bar — round marimba notes"
        case .breath: return "Breath — pure air, almost silent"
        case .heartbeat: return "Heartbeat — lub-dub pulses"
        }
    }
}

/// Synthesizes the dictation sound cues offline and plays them through a
/// shared AVAudioEngine. Ported 1:1 from scripts/sfx-packs.html: every voice
/// runs through a per-voice low-pass plus a master 2 kHz ceiling, so nothing
/// pierces — energy lives at 40–600 Hz ("felt, not heard").
final class SoundPlayer {
    static let shared = SoundPlayer()

    private static let sampleRate = 44_100.0
    private let engine = AVAudioEngine()
    private let nodes: [AVAudioPlayerNode]
    private var nextNode = 0
    private let format = AVAudioFormat(standardFormatWithSampleRate: SoundPlayer.sampleRate, channels: 1)!
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private let lock = NSLock()

    private init() {
        // Three nodes round-robin so overlapping cues (charge into launch)
        // never cut each other off.
        nodes = (0..<3).map { _ in AVAudioPlayerNode() }
        for node in nodes {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        engine.mainMixerNode.outputVolume = 0.9
    }

    func play(_ cue: SoundCue) {
        guard Preferences.shared.soundsEnabled else { return }
        let pack = Preferences.shared.soundPack
        let key = "\(pack.rawValue).\(cue)"
        lock.lock()
        let buffer: AVAudioPCMBuffer
        if let cached = cache[key] {
            buffer = cached
        } else {
            buffer = Self.render(voices: Self.voices(pack: pack, cue: cue))
            cache[key] = buffer
        }
        lock.unlock()

        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        let node = nodes[nextNode]
        nextNode = (nextNode + 1) % nodes.count
        node.stop()
        node.scheduleBuffer(buffer, at: nil)
        node.play()
    }

    // MARK: - Voice tables (mirror of the HTML packs)

    private struct Voice {
        enum Shape { case sine, triangle, sawtooth, noise }
        var shape: Shape = .sine
        var f0: Double = 440
        var f1: Double = 0 // 0 = no sweep; for noise: lp sweep target
        var dur: Double
        var gain: Double
        var delay: Double = 0
        var lp: Double = 2_200
        var attack: Double = 0.004
    }

    /// A thud: sub sine drop plus a whisper of noise for the contact texture.
    private static func thud(
        f0: Double = 80, f1: Double = 42, dur: Double = 0.14, gain: Double = 0.5,
        delay: Double = 0, knock: Double = 0.06
    ) -> [Voice] {
        var voices = [Voice(shape: .sine, f0: f0, f1: f1, dur: dur, gain: gain, delay: delay, lp: 300, attack: 0.002)]
        if knock > 0 {
            voices.append(Voice(shape: .noise, f0: 420, f1: 180, dur: 0.04, gain: knock, delay: delay, attack: 0.002))
        }
        return voices
    }

    private static func voices(pack: SoundPack, cue: SoundCue) -> [Voice] {
        switch (pack, cue) {
        // The certified set (thud-library session): F/C anchor
        // tones, F-centered. Wood Bar F3 ack, Felt Piano C3 merge, Low Swell
        // charge (the god-tier one), Data Splash F arrive (F2→F1 settle).
        case (.sotto, .ack):
            return [
                Voice(shape: .sine, f0: 175, dur: 0.16, gain: 0.3, lp: 800, attack: 0.002),
                Voice(shape: .sine, f0: 350, dur: 0.05, gain: 0.07, lp: 800, attack: 0.002),
            ]
        case (.sotto, .merge):
            return [
                Voice(shape: .sine, f0: 131, dur: 0.25, gain: 0.26, lp: 600, attack: 0.003),
                Voice(shape: .sine, f0: 262, dur: 0.1, gain: 0.06, lp: 600, attack: 0.003),
            ]
        case (.sotto, .charge):
            return [Voice(shape: .sine, f0: 46, f1: 88, dur: 0.55, gain: 0.34, lp: 240, attack: 0.2)]
        case (.sotto, .launch):
            return [Voice(shape: .noise, f0: 520, f1: 130, dur: 0.48, gain: 0.5, attack: 0.01)]
        case (.sotto, .arrive):
            return [
                Voice(shape: .noise, f0: 1_800, f1: 200, dur: 0.13, gain: 0.22, attack: 0.004),
                Voice(shape: .sine, f0: 87, f1: 44, dur: 0.12, gain: 0.3, delay: 0.02, lp: 300, attack: 0.003),
            ]

        case (.velvetThud, .ack):
            return thud(f0: 95, f1: 50, gain: 0.55) + thud(f0: 78, f1: 44, gain: 0.4, delay: 0.1)
        case (.velvetThud, .merge):
            return thud(f0: 82, f1: 40, dur: 0.16, gain: 0.5)
        case (.velvetThud, .charge):
            return [Voice(shape: .sine, f0: 46, f1: 88, dur: 0.5, gain: 0.34, lp: 240, attack: 0.18)]
        case (.velvetThud, .launch):
            return [Voice(shape: .noise, f0: 520, f1: 130, dur: 0.48, gain: 0.5, attack: 0.01)]
        case (.velvetThud, .arrive):
            return thud(f0: 66, f1: 36, dur: 0.18, gain: 0.65, knock: 0.1)

        case (.warmGlass, .ack):
            return [
                Voice(f0: 392, dur: 0.3, gain: 0.12, lp: 1_100),
                Voice(f0: 587, dur: 0.34, gain: 0.07, delay: 0.07, lp: 1_100),
            ] + thud(f0: 70, f1: 48, gain: 0.2, knock: 0)
        case (.warmGlass, .merge):
            return [Voice(f0: 523, f1: 349, dur: 0.22, gain: 0.1, lp: 950)]
                + thud(f0: 75, f1: 45, gain: 0.22, knock: 0)
        case (.warmGlass, .charge):
            return [Voice(shape: .triangle, f0: 131, f1: 196, dur: 0.5, gain: 0.12, lp: 700, attack: 0.16)]
        case (.warmGlass, .launch):
            return [Voice(shape: .noise, f0: 900, f1: 260, dur: 0.45, gain: 0.3, attack: 0.01)]
        case (.warmGlass, .arrive):
            return [
                Voice(f0: 659, dur: 0.2, gain: 0.09, lp: 1_300),
                Voice(f0: 494, dur: 0.26, gain: 0.07, delay: 0.02, lp: 1_100),
            ] + thud(f0: 64, f1: 40, gain: 0.4, knock: 0)

        case (.woodBar, .ack):
            return [
                Voice(f0: 220, dur: 0.2, gain: 0.22, lp: 900),
                Voice(f0: 440, dur: 0.07, gain: 0.06, lp: 900),
                Voice(f0: 262, dur: 0.2, gain: 0.18, delay: 0.11, lp: 900),
            ]
        case (.woodBar, .merge):
            return [Voice(f0: 175, dur: 0.18, gain: 0.2, lp: 800)]
                + thud(f0: 70, f1: 46, gain: 0.2, knock: 0)
        case (.woodBar, .charge):
            return [Voice(shape: .triangle, f0: 98, f1: 147, dur: 0.5, gain: 0.16, lp: 500, attack: 0.15)]
        case (.woodBar, .launch):
            return [Voice(shape: .noise, f0: 700, f1: 200, dur: 0.46, gain: 0.34, attack: 0.01)]
        case (.woodBar, .arrive):
            return [
                Voice(f0: 147, dur: 0.24, gain: 0.28, lp: 700),
                Voice(f0: 294, dur: 0.07, gain: 0.07, lp: 800),
            ]

        case (.breath, .ack):
            return [
                Voice(shape: .noise, f0: 650, f1: 280, dur: 0.16, gain: 0.3, attack: 0.01),
                Voice(shape: .noise, f0: 800, f1: 350, dur: 0.1, gain: 0.2, delay: 0.11, attack: 0.01),
            ]
        case (.breath, .merge):
            return [Voice(shape: .noise, f0: 460, f1: 160, dur: 0.2, gain: 0.32, attack: 0.01)]
        case (.breath, .charge):
            return [Voice(shape: .noise, f0: 180, f1: 520, dur: 0.5, gain: 0.22, attack: 0.2)]
        case (.breath, .launch):
            return [Voice(shape: .noise, f0: 1_000, f1: 170, dur: 0.5, gain: 0.42, attack: 0.01)]
        case (.breath, .arrive):
            return [Voice(shape: .noise, f0: 380, f1: 200, dur: 0.08, gain: 0.3, attack: 0.01)]
                + thud(f0: 58, f1: 38, dur: 0.12, gain: 0.4, knock: 0)

        case (.heartbeat, .ack):
            return thud(f0: 62, f1: 44, dur: 0.1, gain: 0.5, knock: 0)
                + thud(f0: 54, f1: 40, dur: 0.1, gain: 0.34, delay: 0.15, knock: 0)
        case (.heartbeat, .merge):
            return thud(f0: 58, f1: 40, dur: 0.13, gain: 0.4, knock: 0)
        case (.heartbeat, .charge):
            return [0.0, 0.17, 0.3, 0.4].enumerated().flatMap { index, delay in
                thud(
                    f0: 60 + Double(index) * 4, f1: 42, dur: 0.09,
                    gain: 0.25 + Double(index) * 0.07, delay: delay, knock: 0)
            }
        case (.heartbeat, .launch):
            return [
                Voice(shape: .sawtooth, f0: 190, f1: 55, dur: 0.45, gain: 0.16, lp: 280),
                Voice(shape: .noise, f0: 380, f1: 110, dur: 0.45, gain: 0.3, attack: 0.01),
            ]
        case (.heartbeat, .arrive):
            return thud(f0: 68, f1: 34, dur: 0.2, gain: 0.7, knock: 0.08)
        }
    }

    // MARK: - Offline synthesis

    private static func render(voices: [Voice]) -> AVAudioPCMBuffer {
        let sr = sampleRate
        let total = voices.map { $0.delay + $0.dur + 0.05 }.max() ?? 0.1
        let frames = AVAudioFrameCount(total * sr)
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { out[i] = 0 }

        var noiseState: UInt64 = 0x9E37_79B9_7F4A_7C15
        func whiteNoise() -> Double {
            noiseState ^= noiseState << 13
            noiseState ^= noiseState >> 7
            noiseState ^= noiseState << 17
            return Double(Int64(bitPattern: noiseState)) / Double(Int64.max)
        }

        for voice in voices {
            let start = Int(voice.delay * sr)
            let count = Int(voice.dur * sr)
            guard count > 0 else { continue }
            var phase = 0.0
            var lpState = 0.0
            var ceilState = 0.0
            let ceilCoef = 1 - exp(-2 * .pi * 2_000 / sr)
            let sweeps = voice.f1 > 0 && voice.f1 != voice.f0
            for i in 0..<count {
                let t = Double(i) / sr
                let progress = t / voice.dur
                // Envelope: linear attack, exponential decay to silence.
                let amp: Double
                if t < voice.attack {
                    amp = voice.gain * (t / voice.attack)
                } else {
                    let decay = (t - voice.attack) / max(voice.dur - voice.attack, 0.001)
                    amp = voice.gain * pow(0.0001 / voice.gain, decay)
                }
                var sample: Double
                var cutoff = voice.lp
                if voice.shape == .noise {
                    sample = whiteNoise()
                    // For noise, f0→f1 is the low-pass sweep itself.
                    cutoff = sweeps ? voice.f0 * pow(voice.f1 / voice.f0, progress) : voice.f0
                } else {
                    let freq = sweeps ? voice.f0 * pow(voice.f1 / voice.f0, progress) : voice.f0
                    phase += freq / sr
                    let p = phase.truncatingRemainder(dividingBy: 1)
                    switch voice.shape {
                    case .sine: sample = sin(2 * .pi * p)
                    case .triangle: sample = 4 * abs(p - 0.5) - 1
                    case .sawtooth: sample = 2 * p - 1
                    case .noise: sample = 0
                    }
                }
                // Per-voice low-pass, then the master 2 kHz ceiling.
                let lpCoef = 1 - exp(-2 * .pi * min(cutoff, 12_000) / sr)
                lpState += lpCoef * (sample - lpState)
                ceilState += ceilCoef * (lpState - ceilState)
                let index = start + i
                if index < Int(frames) { out[index] += Float(ceilState * amp) }
            }
        }
        // Soft clip guard.
        for i in 0..<Int(frames) { out[i] = max(-1, min(1, out[i])) }
        return buffer
    }
}
