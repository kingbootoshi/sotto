import Foundation
import FluidAudio

/// Wraps FluidAudio's Parakeet TDT manager. One canonical path: prepare once,
/// transcribe WAV files from disk (the durable artifact) with a fresh decoder
/// state per dictation.
final class TranscriptionEngine {
    enum Status: Equatable {
        case idle
        case loading
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Model: not loaded"
            case .loading: return "Model: downloading / loading…"
            case .ready: return "Model: ready"
            case .failed(let message): return "Model failed: \(message)"
            }
        }
    }

    private(set) var status: Status = .idle
    private var manager: AsrManager?
    /// AsrManager owns shared mutable ANE buffers: overlapping calls corrupt
    /// each other. Every transcription chains behind the previous one.
    /// ponytail: callers are main-thread only (controller + CLI); `tail` is
    /// unguarded on that assumption.
    private var tail: Task<Void, Never> = Task {}
    var onStatusChange: ((Status) -> Void)?

    var isReady: Bool { status == .ready }

    func prepare(version: AsrModelVersion) async throws {
        setStatus(.loading)
        manager = nil
        do {
            let models = try await AsrModels.downloadAndLoad(version: version)
            manager = AsrManager(config: .default, models: models)
            setStatus(.ready)
        } catch {
            setStatus(.failed(error.localizedDescription))
            throw error
        }
    }

    func transcribe(url: URL) async throws -> ASRResult {
        guard let manager else { throw SottoError.modelsNotReady }
        let prev = tail
        let job = Task { () throws -> ASRResult in
            await prev.value
            var decoderState = try TdtDecoderState(decoderLayers: 2)
            return try await manager.transcribe(url, decoderState: &decoderState)
        }
        tail = Task { _ = try? await job.value }
        return try await job.value
    }

    private func setStatus(_ status: Status) {
        self.status = status
        let callback = onStatusChange
        DispatchQueue.main.async { callback?(status) }
    }
}
