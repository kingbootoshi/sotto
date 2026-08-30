import AppKit
import Foundation

// `sotto transcribe <file>` — headless self-check that exercises the exact
// engine the app uses. This is the runnable proof for the ASR path.
let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "transcribe" {
    let url = URL(fileURLWithPath: arguments[2])
    HistoryStore.repairWavHeader(at: url)
    Task {
        do {
            let engine = TranscriptionEngine()
            try await engine.prepare(version: Preferences.shared.modelVersion)
            let result = try await engine.transcribe(url: url)
            print(result.text)
            let stats = String(
                format: "confidence=%.3f audio=%.2fs processing=%.2fs\n",
                result.confidence, result.duration, result.processingTime)
            FileHandle.standardError.write(Data(stats.utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
} else if arguments.count >= 2, arguments[1] == "designpreview" {
    MainActor.assumeIsolated { runDesignPreview() }
} else if arguments.count >= 2, arguments[1] == "historypreview" {
    // Headless-ish smoke test: open only the History window over real data.
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        installMainMenu()
        app.setActivationPolicy(.regular)
        HistoryWindowController.shared.show()
        app.run()
    }
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
