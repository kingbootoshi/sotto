import AVFoundation
import Foundation

/// Streams the default input device into a WAV file at the device's native
/// format. FluidAudio's AudioConverter normalizes to 16 kHz mono at
/// transcription time, so the recording stays a faithful raw artifact.
final class Recorder {
    private let engine = AVAudioEngine()
    /// Guarded by bufferClock: the audio thread reads `file` per buffer while
    /// the main thread swaps it on start/stop of a take.
    private var file: AVAudioFile?
    private(set) var fileURL: URL?
    private var startedAt: Date?
    private var configObserver: NSObjectProtocol?
    private var writeFailures = 0
    /// Hot-mic window: the engine keeps running briefly after a take so a
    /// rapid next tap starts with zero spin-up. Costs 8s of orange mic dot.
    private var engineHot = false
    private var cooldown: Timer?
    /// Written on the audio thread, read by the watchdog on main. Guarded
    /// because the watchdog must never misread a torn value into a false
    /// interrupt during a live take.
    private let bufferClock = NSLock()
    private var lastBufferAt = Date()
    private var watchdog: Timer?
    /// Rolling peak for the waveform auto-leveler.
    private var peak: Float = 0.08

    /// Normalized display level per buffer, called on the audio thread.
    var onLevel: ((Float) -> Void)?
    /// Called on the main thread when capture dies mid-recording (device
    /// changed or disk writes keep failing). The owner must finish and save.
    var onInterrupt: (() -> Void)?

    var isRecording: Bool { startedAt != nil }

    func start(to url: URL) throws {
        cooldown?.invalidate()
        cooldown = nil
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SottoError.noMicrophone }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let newFile = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        bufferClock.lock()
        file = newFile
        bufferClock.unlock()
        fileURL = url

        if !engineHot {
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.bufferClock.lock()
                let file = self.file
                self.lastBufferAt = Date()
                self.bufferClock.unlock()
                guard let file else { return }
                do {
                    try file.write(from: buffer)
                    self.writeFailures = 0
                } catch {
                    // A full or failing disk must end the take safely, not eat it.
                    self.writeFailures += 1
                    if self.writeFailures == 5 {
                        DispatchQueue.main.async { self.onInterrupt?() }
                    }
                }
                self.onLevel?(self.displayLevel(buffer))
            }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                // A dead tap left installed would crash the next install.
                input.removeTap(onBus: 0)
                throw error
            }
            engineHot = true
            // Input device changed or vanished (AirPods disconnect, dock
            // unplug): mid-take, save what was captured; while merely hot,
            // go cold so the next take rebuilds against the new device.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                if self.isRecording {
                    self.onInterrupt?()
                } else {
                    self.goCold()
                }
            }
        }
        startedAt = Date()
        writeFailures = 0
        peak = 0.08
        bufferClock.lock()
        lastBufferAt = Date()
        bufferClock.unlock()
        // The config-change notification does not always fire when input
        // dies (some device drops just go quiet). Buffers arriving is the
        // only honest liveness signal: 3 silent seconds = the take is over,
        // save it.
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self, self.isRecording else { return timer.invalidate() }
            self.bufferClock.lock()
            let quiet = Date().timeIntervalSince(self.lastBufferAt)
            self.bufferClock.unlock()
            if quiet > 3.0 {
                timer.invalidate()
                self.onInterrupt?()
            }
        }
    }

    /// Stops and returns the captured duration. The WAV stays on disk.
    @discardableResult
    func stop() -> TimeInterval {
        watchdog?.invalidate()
        watchdog = nil
        bufferClock.lock()
        file = nil
        bufferClock.unlock()
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        cooldown = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            self?.goCold()
        }
        return duration
    }

    private func goCold() {
        guard engineHot, !isRecording else { return }
        cooldown?.invalidate()
        cooldown = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engineHot = false
    }


    /// Waveform feel locked from the HTML prototype (gain 7, curve .75,
    /// auto-level .6): blends absolute loudness with a rolling-peak
    /// normalizer so the bars dance at speaking volume without pinning.
    private func displayLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = (sum / Float(count)).squareRoot()
        // ~23 buffers/s at 2048 frames; 0.987^23 ≈ the prototype's 0.995^60.
        peak = max(rms, peak * 0.987, 0.015)
        let norm = 0.4 * rms * 7 + 0.6 * (rms / peak)
        return min(1, pow(norm, 0.75))
    }
}
