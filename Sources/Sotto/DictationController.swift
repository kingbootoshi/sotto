import AVFoundation
import AppKit
import Foundation

/// State machine: idle → arming → recording → transcribing → idle.
/// Every recording becomes a durable WAV before transcription; failures keep
/// the WAV and say so. Nothing is ever pasted unless a transcript exists.
@MainActor
final class DictationController {
    enum State {
        case idle
        case arming
        case recording(id: UUID, url: URL)
        case transcribing
    }

    private(set) var state: State = .idle
    private var releasedWhileArming = false
    private var hotkeyDownAt = Date.distantPast
    /// Where the comet shoots: the mouse position at the stop tap - the
    /// microsecond the hotkey lands is the intent moment; the hand is
    /// already moving on while transcription and the charge run.
    private var aimAtStop = CGPoint.zero

    private let recorder = Recorder()
    private let overlay = OverlayPanelController()
    private let history = HistoryStore.shared
    private let flight = CometFlightController()
    let engine = TranscriptionEngine()

    var onStateChange: ((State) -> Void)?

    private var minimumDuration: TimeInterval { 0.35 }
    /// Down-to-up gap that separates a tap (toggle) from a hold (push-to-talk).
    private var holdThreshold: TimeInterval { 0.5 }

    func hotkeyDown() {
        switch state {
        case .recording(let id, let url):
            // Toggle off: a second tap ends the dictation.
            finishRecording(id: id, url: url)
        case .idle:
            guard engine.isReady else {
                overlay.show(phase: .error("The speech model is still loading. Try again in a moment."))
                overlay.hide(after: 1.8)
                return
            }
            hotkeyDownAt = Date()
            setState(.arming)
            releasedWhileArming = false
            Task { await beginRecording() }
        default:
            break
        }
    }

    func hotkeyUp() {
        // A quick tap toggles: the release is ignored and recording continues
        // until the next tap. A long hold is push-to-talk: release finishes.
        guard Date().timeIntervalSince(hotkeyDownAt) >= holdThreshold else { return }
        switch state {
        case .arming:
            releasedWhileArming = true
        case .recording(let id, let url):
            finishRecording(id: id, url: url)
        default:
            break
        }
    }

    func escapePressed() {
        guard case .recording = state else { return }
        recorder.cancel()
        overlay.hide()
        setState(.idle)
    }

    private func beginRecording() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            overlay.show(phase: .error(SottoError.microphoneDenied.localizedDescription))
            overlay.hide(after: 3.5)
            setState(.idle)
            return
        }
        guard case .arming = state else { return }

        let id = UUID()
        do {
            let url = try history.newRecordingURL(id: id)
            recorder.onLevel = { [weak self] level in
                DispatchQueue.main.async { self?.overlay.model.pushLevel(level) }
            }
            recorder.onInterrupt = { [weak self] in
                guard let self, case .recording(let id, let url) = self.state else { return }
                // Mic vanished or disk writes failed: the words on disk are
                // worth more than a clean session. Save and transcribe now.
                self.finishRecording(id: id, url: url)
            }
            try recorder.start(to: url)
            setState(.recording(id: id, url: url))
            overlay.model.resetLevels()
            overlay.show(phase: .listening)
            SoundPlayer.shared.play(.ack)
            if releasedWhileArming {
                // Key came back up before the engine finished starting.
                finishRecording(id: id, url: url)
            }
        } catch {
            recorder.cancel()
            overlay.show(phase: .error("Could not start recording: \(error.localizedDescription)"))
            overlay.hide(after: 3.5)
            setState(.idle)
        }
    }

    private func finishRecording(id: UUID, url: URL) {
        // First statement: the stop tap IS the aim moment.
        aimAtStop = NSEvent.mouseLocation
        let duration = recorder.stop()
        guard duration >= minimumDuration else {
            try? FileManager.default.removeItem(at: url)
            overlay.hide()
            setState(.idle)
            return
        }
        setState(.transcribing)
        SoundPlayer.shared.play(.merge)
        overlay.mergeToOrb()
        Task { await transcribe(id: id, url: url, duration: duration) }
    }

    private func transcribe(id: UUID, url: URL, duration: TimeInterval) async {
        let modelName = Preferences.shared.modelLabel
        do {
            let result = try await engine.transcribe(url: url)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            history.finalize(
                record: DictationRecord(
                    id: id, createdAt: Date(), duration: duration, model: modelName,
                    text: text, confidence: result.confidence,
                    processingTime: result.processingTime, error: nil),
                wavURL: url)
            if text.isEmpty {
                overlay.update(phase: .error("Heard no words. The recording is kept in History."))
                overlay.hide(after: 2.5)
            } else {
                // Clipboard first — the words are safe before any cinematic.
                Paster.copy(text)
                if AXIsProcessTrusted() {
                    await launchComet()
                } else {
                    overlay.update(phase: .error(
                        "Copied to the clipboard — press ⌘V. Turn on Sotto in System Settings, Privacy, Accessibility for automatic paste."))
                    overlay.hide(after: 5)
                }
            }
        } catch {
            history.finalize(
                record: DictationRecord(
                    id: id, createdAt: Date(), duration: duration, model: modelName,
                    text: nil, confidence: nil, processingTime: nil,
                    error: String(describing: error)),
                wavURL: url)
            overlay.update(
                phase: .error("Transcription failed. The recording is kept in History."))
            overlay.hide(after: 3.5)
        }
        setState(.idle)
    }

    /// The Comet cinematic: charge the orb, then beam it straight to the
    /// live mouse cursor, paste on arrival. The transcript is already on the
    /// clipboard before any animation - the cinematic can die without losing
    /// words.
    private func launchComet() async {
        overlay.model.charging = true
        SoundPlayer.shared.play(.charge)
        try? await Task.sleep(nanoseconds: 520_000_000)
        overlay.model.charging = false
        let start = overlay.orbCenter
        SoundPlayer.shared.play(.launch)
        overlay.vanish()
        flight.fly(from: start, aim: aimAtStop) {
            SoundPlayer.shared.play(.arrive)
            Paster.sendCmdV()
        }
    }

    /// Transcribes WAVs that never got a JSON record (crash recovery).
    func recoverUnfinished() async -> Int {
        let pending = history.unfinishedRecordings()
        guard !pending.isEmpty, engine.isReady else { return 0 }
        var recovered = 0
        for url in pending {
            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            HistoryStore.repairWavHeader(at: url)
            do {
                let result = try await engine.transcribe(url: url)
                history.finalize(
                    record: DictationRecord(
                        id: id, createdAt: Date(), duration: result.duration,
                        model: Preferences.shared.modelLabel,
                        text: result.text, confidence: result.confidence,
                        processingTime: result.processingTime, error: nil),
                    wavURL: url)
                recovered += 1
            } catch {
                NSLog("Sotto: recovery failed for \(url.lastPathComponent): \(error)")
            }
        }
        return recovered
    }

    private func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }
}
