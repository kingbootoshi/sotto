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
    }

    private(set) var state: State = .idle
    private var releasedWhileArming = false
    private var hotkeyDownAt = Date.distantPast
    /// Where the comet shoots: the mouse position at the stop tap - the
    /// microsecond the hotkey lands is the intent moment; the hand is
    /// already moving on while transcription and the charge run.
    private var aimAtStop = CGPoint.zero
    /// Only the pasteboard critical section (re-copy → ⌘V posted) is
    /// serialized between takes; transcriptions chain inside the engine and
    /// comets fly concurrently. Rapid takes pew-pew instead of queueing.
    private var pasteTail: Task<Void, Never>?
    /// Bumped whenever a newer take claims the overlay; an older delivery
    /// seeing a stale generation skips visuals (its words are already safe).
    private var overlayGen = 0

    private let recorder = Recorder()
    private let overlay = OverlayPanelController()
    private let history = HistoryStore.shared
    private let flight = CometFlightController()
    let engine = TranscriptionEngine()

    var onStateChange: ((State) -> Void)?

    private var minimumDuration: TimeInterval { 0.35 }
    /// Down-to-up gap that separates a tap (toggle) from a hold (push-to-talk).
    private var holdThreshold: TimeInterval { 0.5 }
    /// The certified charge beat: the orb pulses this long at minimum while
    /// transcription runs underneath it.
    private var chargeBeat: TimeInterval { 0.52 }

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
        guard case .recording(let id, let url) = state else { return }
        // Esc aborts the DELIVERY, never the audio: the take is stopped,
        // kept, and transcribed straight into History with no paste. Global
        // Esc is fired constantly (vim, dialogs) - it must never eat words.
        let duration = recorder.stop()
        overlayGen += 1
        overlay.hide()
        setState(.idle)
        guard duration > 0.05 else { return discardEmptyContainer(url) }
        enqueueDelivery(id: id, url: url, duration: duration, deliver: false)
    }

    private func beginRecording() async {
        // The sync status check keeps the granted path free of an async hop:
        // the permission dialog is a first-run event, not a per-take cost.
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                overlay.show(phase: .error(SottoError.microphoneDenied.localizedDescription))
                overlay.hide(after: 3.5)
                setState(.idle)
                return
            }
        }
        guard case .arming = state else { return }

        let id = UUID()
        guard let url = try? history.newRecordingURL(id: id) else {
            overlay.show(phase: .error("Could not create a recording file. Check your disk space."))
            overlay.hide(after: 3.5)
            setState(.idle)
            return
        }
        do {
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
            overlayGen += 1
            overlay.model.resetLevels()
            overlay.show(phase: .listening)
            SoundPlayer.shared.play(.ack)
            if releasedWhileArming {
                // Key came back up before the engine finished starting.
                finishRecording(id: id, url: url)
            }
        } catch {
            recorder.stop()
            discardEmptyContainer(url)
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
            // Accidental blip: no words possible, but audio is never deleted -
            // only a container with no audio in it may be discarded.
            discardEmptyContainer(url)
            overlay.hide()
            setState(.idle)
            return
        }
        setState(.idle)
        SoundPlayer.shared.play(.merge)
        overlay.mergeToOrb()
        SoundPlayer.shared.play(.charge)
        overlay.model.charging = true
        enqueueDelivery(id: id, url: url, duration: duration, deliver: true)
    }

    /// Fires one take's delivery (transcribe → charge → flight → paste).
    /// Deliveries overlap; the paste chain alone enforces exclusivity.
    private func enqueueDelivery(id: UUID, url: URL, duration: TimeInterval, deliver: Bool) {
        let aim = aimAtStop
        let chargeStart = Date()
        let gen = overlayGen
        Task { [weak self] in
            await self?.transcribe(
                id: id, url: url, duration: duration,
                aim: aim, chargeStart: chargeStart, gen: gen, deliver: deliver)
        }
    }

    /// The pasteboard critical section: each arrival re-copies its own
    /// transcript immediately before ⌘V, so overlapping deliveries can
    /// never paste another take's words.
    private func enqueuePaste(_ text: String) {
        let prev = pasteTail
        pasteTail = Task {
            await prev?.value
            Paster.copy(text)
            await withCheckedContinuation { continuation in
                Paster.sendCmdV { continuation.resume() }
            }
        }
    }

    /// The ONLY removal in the app, and it refuses anything holding audio:
    /// a WAV at header size (< 8 KB ≈ 0.02 s) contains no speech. Anything
    /// larger survives as an unfinished take and gets transcribed.
    private func discardEmptyContainer(_ url: URL) {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if bytes < 8192 {
            try? FileManager.default.removeItem(at: url)
        } else {
            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            enqueueDelivery(id: id, url: url, duration: 0, deliver: false)
        }
    }

    private func transcribe(
        id: UUID, url: URL, duration: TimeInterval,
        aim: CGPoint = .zero, chargeStart: Date = .distantPast,
        gen: Int = -1, deliver: Bool = true
    ) async {
        let modelName = Preferences.shared.modelLabel
        // History sorts by createdAt = when the words were SPOKEN, not when
        // transcription finished - recovery order must match speaking order.
        let startedAt = Date().addingTimeInterval(-duration)
        do {
            let result = try await engine.transcribe(url: url)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            history.finalize(
                record: DictationRecord(
                    id: id, createdAt: startedAt, duration: duration, model: modelName,
                    text: text, confidence: result.confidence,
                    processingTime: result.processingTime, error: nil),
                wavURL: url)
            let owns = gen == overlayGen
            if !deliver {
                // Esc / blip salvage: the words are safe in History; no
                // paste, no cinematic, no overlay - the user moved on.
            } else if text.isEmpty {
                if owns {
                    overlay.update(phase: .error("Heard no words. The recording is kept in History."))
                    overlay.hide(after: 2.5)
                }
            } else {
                // Clipboard first — the words are safe before any cinematic.
                Paster.copy(text)
                if AXIsProcessTrusted() {
                    await launchComet(aim: aim, chargeStart: chargeStart, gen: gen, text: text)
                } else if owns {
                    overlay.update(phase: .error(
                        "Copied to the clipboard — press ⌘V. Turn on Sotto in System Settings, Privacy, Accessibility for automatic paste."))
                    overlay.hide(after: 5)
                }
            }
        } catch {
            history.finalize(
                record: DictationRecord(
                    id: id, createdAt: startedAt, duration: duration, model: modelName,
                    text: nil, confidence: nil, processingTime: nil,
                    error: String(describing: error)),
                wavURL: url)
            NSLog("Sotto: transcription failed for \(url.lastPathComponent): \(error)")
            if deliver, gen == overlayGen {
                overlay.update(
                    phase: .error("Transcription failed. The recording is kept in History."))
                overlay.hide(after: 3.5)
            }
        }
    }

    /// The Comet cinematic: the charge began the instant the stop tap
    /// landed, transcription already ran underneath it - only the beat's
    /// remainder is waited out here. The transcript is on the clipboard
    /// before any animation; the cinematic can die without losing words.
    private func launchComet(aim: CGPoint, chargeStart: Date, gen: Int, text: String) async {
        let remaining = chargeBeat - Date().timeIntervalSince(chargeStart)
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        let start = overlay.orbCenter
        if gen == overlayGen {
            overlay.model.charging = false
            overlay.vanish()
        }
        SoundPlayer.shared.play(.launch)
        flight.fly(from: start, aim: aim) { [weak self] in
            SoundPlayer.shared.play(.arrive)
            self?.enqueuePaste(text)
        }
    }

    /// Transcribes WAVs that never got a JSON record (crash recovery).
    func recoverUnfinished() async -> Int {
        let pending = history.unfinishedRecordings()
        guard !pending.isEmpty, engine.isReady else { return 0 }
        var recovered = 0
        for url in pending {
            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            let spokenAt = Self.recordingDate(of: url)
            HistoryStore.repairWavHeader(at: url)
            do {
                let result = try await engine.transcribe(url: url)
                history.finalize(
                    record: DictationRecord(
                        id: id, createdAt: spokenAt, duration: result.duration,
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

    /// Re-transcribes one WAV from the History window (unfinished or failed
    /// takes). Overwrites the record beside the WAV on success or failure.
    func retryTranscription(url: URL) async -> Bool {
        guard engine.isReady else { return false }
        let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
        let spokenAt = Self.recordingDate(of: url)
        HistoryStore.repairWavHeader(at: url)
        do {
            let result = try await engine.transcribe(url: url)
            history.finalize(
                record: DictationRecord(
                    id: id, createdAt: spokenAt, duration: result.duration,
                    model: Preferences.shared.modelLabel,
                    text: result.text, confidence: result.confidence,
                    processingTime: result.processingTime, error: nil),
                wavURL: url)
            return true
        } catch {
            history.finalize(
                record: DictationRecord(
                    id: id, createdAt: spokenAt, duration: 0,
                    model: Preferences.shared.modelLabel,
                    text: nil, confidence: nil, processingTime: nil,
                    error: String(describing: error)),
                wavURL: url)
            NSLog("Sotto: retry failed for \(url.lastPathComponent): \(error)")
            return false
        }
    }

    /// The WAV's creation date is when the words were actually spoken -
    /// recovered and retried records must keep their true place in History.
    private static func recordingDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    }

    private func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }
}
