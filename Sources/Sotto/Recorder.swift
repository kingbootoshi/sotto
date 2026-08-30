import AVFoundation
import Foundation

/// Streams the default input device into a WAV file at the device's native
/// format. FluidAudio's AudioConverter normalizes to 16 kHz mono at
/// transcription time, so the recording stays a faithful raw artifact.
final class Recorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private(set) var fileURL: URL?
    private var startedAt: Date?
    private var configObserver: NSObjectProtocol?
    private var writeFailures = 0
    /// Rolling peak for the waveform auto-leveler.
    private var peak: Float = 0.08

    /// Normalized display level per buffer, called on the audio thread.
    var onLevel: ((Float) -> Void)?
    /// Called on the main thread when capture dies mid-recording (device
    /// changed or disk writes keep failing). The owner must finish and save.
    var onInterrupt: (() -> Void)?

    var isRecording: Bool { startedAt != nil }

    func start(to url: URL) throws {
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
        file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        fileURL = url

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
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
        try engine.start()
        startedAt = Date()
        writeFailures = 0
        peak = 0.08
        // Input device changed or vanished (AirPods disconnect, dock unplug):
        // the engine stops delivering buffers. Save what was captured.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.onInterrupt?()
        }
    }

    /// Stops and returns the captured duration. The WAV stays on disk.
    @discardableResult
    func stop() -> TimeInterval {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        return duration
    }

    /// Stops and deletes the partial WAV (explicit user cancel only).
    func cancel() {
        let url = fileURL
        stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
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
