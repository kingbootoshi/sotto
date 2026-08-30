import AppKit
import Foundation

struct DictationRecord: Codable {
    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
    let model: String
    let text: String?
    let confidence: Float?
    let processingTime: TimeInterval?
    let error: String?
}

/// File-first durable history, Spokenly-compatible in spirit:
/// History/yyyy-MM-dd/UUID.wav + UUID.json. The WAV lands on disk while
/// recording; the JSON is written atomically after transcription. A WAV
/// without a JSON is, by definition, an unfinished dictation to recover.
final class HistoryStore {
    static let shared = HistoryStore()

    let baseURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Sotto/History", isDirectory: true)
    }()

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    func newRecordingURL(id: UUID, date: Date = Date()) throws -> URL {
        let dayDir = baseURL.appendingPathComponent(dayFormatter.string(from: date), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        return dayDir.appendingPathComponent("\(id.uuidString).wav")
    }

    func finalize(record: DictationRecord, wavURL: URL) {
        let jsonURL = wavURL.deletingPathExtension().appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(record)
            try data.write(to: jsonURL, options: .atomic)
        } catch {
            NSLog("Sotto: failed to write history record: \(error)")
        }
    }

    /// One row in the History window: a finished record (JSON, usually with
    /// its WAV beside it) or an unfinished WAV awaiting recovery.
    struct Entry: Identifiable {
        let id: UUID
        let createdAt: Date
        let record: DictationRecord?
        let wavURL: URL?
        var text: String? { record?.text }
        var duration: TimeInterval? { record?.duration }
        var error: String? { record?.error }
        var isUnfinished: Bool { record == nil }
    }

    /// Every dictation on disk, newest first.
    func allEntries() -> [Entry] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: baseURL, includingPropertiesForKeys: [.creationDateKey])
        else { return [] }
        var wavs: [String: URL] = [:]
        var jsons: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "wav" { wavs[url.deletingPathExtension().path] = url }
            if url.pathExtension == "json" { jsons.append(url) }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [Entry] = []
        for jsonURL in jsons {
            let stem = jsonURL.deletingPathExtension().path
            guard let data = try? Data(contentsOf: jsonURL),
                let record = try? decoder.decode(DictationRecord.self, from: data)
            else { continue }
            entries.append(
                Entry(
                    id: record.id, createdAt: record.createdAt, record: record,
                    wavURL: wavs.removeValue(forKey: stem)))
        }
        for (_, wavURL) in wavs {
            let created =
                (try? wavURL.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantPast
            let id = UUID(uuidString: wavURL.deletingPathExtension().lastPathComponent) ?? UUID()
            entries.append(Entry(id: id, createdAt: created, record: nil, wavURL: wavURL))
        }
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    /// Moves a dictation's WAV+JSON pair to the Trash.
    func trash(_ entry: Entry) {
        let urls = [
            entry.wavURL,
            entry.wavURL?.deletingPathExtension().appendingPathExtension("json"),
        ]
        for case let url? in urls {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        if entry.wavURL == nil, let record = entry.record {
            // JSON-only record: find it by id across day folders.
            if let enumerator = FileManager.default.enumerator(at: baseURL, includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator
                where url.lastPathComponent == "\(record.id.uuidString).json" {
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            }
        }
    }

    /// WAV files that never got a JSON record (crash or force-quit mid-flight).
    func unfinishedRecordings() -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: baseURL, includingPropertiesForKeys: nil)
        else { return [] }
        var wavs: [URL] = []
        var jsonStems = Set<String>()
        for case let url as URL in enumerator {
            if url.pathExtension == "wav" { wavs.append(url) }
            if url.pathExtension == "json" { jsonStems.insert(url.deletingPathExtension().path) }
        }
        return wavs.filter { !jsonStems.contains($0.deletingPathExtension().path) }
    }

    /// AVAudioFile only finalizes the RIFF/data chunk sizes on clean close.
    /// A crash mid-recording leaves audio on disk behind a header that claims
    /// zero bytes, which readers reject. Rewrite the sizes from the real file
    /// length so recovery can transcribe every captured sample.
    static func repairWavHeader(at url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 44 else { return }

        func read(_ offset: UInt64, _ count: Int) -> Data? {
            guard (try? handle.seek(toOffset: offset)) != nil,
                let data = try? handle.read(upToCount: count), data.count == count
            else { return nil }
            return data
        }
        func writeUInt32(_ value: UInt32, at offset: UInt64) {
            var le = value.littleEndian
            guard (try? handle.seek(toOffset: offset)) != nil else { return }
            try? handle.write(contentsOf: Data(bytes: &le, count: 4))
        }

        guard let header = read(0, 12),
            header.prefix(4).elementsEqual("RIFF".utf8),
            header.suffix(4).elementsEqual("WAVE".utf8)
        else { return }

        var offset: UInt64 = 12
        while offset + 8 <= fileSize {
            guard let chunk = read(offset, 8) else { return }
            let size = chunk.subdata(in: 4..<8).withUnsafeBytes {
                UInt32(littleEndian: $0.load(as: UInt32.self))
            }
            if chunk.prefix(4).elementsEqual("data".utf8) {
                let actual = UInt32(truncatingIfNeeded: fileSize - offset - 8)
                if size != actual {
                    writeUInt32(UInt32(truncatingIfNeeded: fileSize - 8), at: 4)
                    writeUInt32(actual, at: offset + 4)
                    NSLog("Sotto: repaired WAV header for \(url.lastPathComponent)")
                }
                return
            }
            offset += 8 + UInt64(size) + UInt64(size % 2)
        }
    }

    func openInFinder() {
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(baseURL)
    }
}
