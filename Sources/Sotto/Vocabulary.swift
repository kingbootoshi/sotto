import Foundation

/// The spoken-form dictionary: how a word is SAID on the left, what must be
/// WRITTEN on the right. Applied on the one canonical path (the engine), so
/// live takes, Esc salvage, crash recovery, and History retries all agree.
/// ponytail: deterministic text substitution, not acoustic biasing - the
/// upgrade path is FluidAudio's CTC vocabulary boosting, which requires the
/// Unified/SlidingWindow manager plus separate CTC models.
enum Vocabulary {
    static let fileURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Sotto/vocabulary.txt")
    }()

    private static let seed = """
        # Sotto vocabulary - how you say it = how it gets written.
        # One rule per line, spoken form on the left. Case-insensitive,
        # whole words only, multi-word phrases allowed. Lines starting
        # with # are comments. Saved edits apply to the very next take.

        clawed = Claude
        clawed code = Claude Code
        cloud code = Claude Code
        """

    /// Creates the file with the starter rules on first use.
    static func ensureFile() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? seed.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Reparsed per transcript: ~a few dozen lines, so freshness is free and
    /// there is no reload button to forget.
    static func rules() -> [(spoken: String, written: String)] {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let spoken = parts[0].trimmingCharacters(in: .whitespaces)
            let written = parts[1].trimmingCharacters(in: .whitespaces)
            guard !spoken.isEmpty, !written.isEmpty else { return nil }
            return (spoken, written)
        }
        // Longest spoken form first, so "clawed code" wins over "clawed".
        .sorted { $0.spoken.count > $1.spoken.count }
    }

    static func apply(_ text: String) -> String {
        var out = text
        for (spoken, written) in rules() {
            guard
                let regex = try? NSRegularExpression(
                    pattern: "\\b" + NSRegularExpression.escapedPattern(for: spoken) + "\\b",
                    options: [.caseInsensitive])
            else { continue }
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: NSRegularExpression.escapedTemplate(for: written))
        }
        return out
    }
}
