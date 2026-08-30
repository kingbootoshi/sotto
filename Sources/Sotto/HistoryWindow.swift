import AppKit
import AVFoundation
import SwiftUI

/// The glass History window: every dictation newest-first, searchable, with
/// per-row play/copy/delete. Exists so a mis-pasted prompt is never lost -
/// the core action is Copy. The folder icon in the header opens Finder for
/// the rare raw-file need.
@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()
    private var window: NSWindow?
    var retryHandler: ((URL) async -> Bool)?

    func show() {
        if window == nil {
            let model = HistoryModel()
            model.retryHandler = { [weak self] url in await self?.retryHandler?(url) ?? false }
            let view = HistoryView(model: model)
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            win.title = "History"
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.minSize = NSSize(width: 440, height: 320)
            win.isReleasedWhenClosed = false
            win.center()

            let host = NSHostingView(rootView: view)
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.autoresizingMask = [.width, .height]
            host.frame = effect.bounds
            host.autoresizingMask = [.width, .height]
            effect.addSubview(host)
            win.contentView = effect
            window = win
        }
        (window?.contentView?.subviews.first as? NSHostingView<HistoryView>)?
            .rootView.model.reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryStore.Entry] = []
    @Published var query = ""
    @Published var playingID: UUID?
    @Published var copiedID: UUID?
    @Published var retryingID: UUID?
    var retryHandler: ((URL) async -> Bool)?
    private var player: AVAudioPlayer?
    private var playerWatch: Timer?

    var filtered: [HistoryStore.Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { ($0.text ?? "").localizedCaseInsensitiveContains(trimmed) }
    }

    func reload() {
        Task { [weak self] in
            let all = await Task.detached { HistoryStore.shared.allEntries() }.value
            self?.entries = all
        }
    }

    func copy(_ entry: HistoryStore.Entry) {
        guard let text = entry.text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedID = entry.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedID == entry.id { copiedID = nil }
        }
    }

    func togglePlay(_ entry: HistoryStore.Entry) {
        if playingID == entry.id {
            player?.stop()
            playingID = nil
            return
        }
        guard let url = entry.wavURL, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        p.play()
        playingID = entry.id
        playerWatch?.invalidate()
        playerWatch = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return timer.invalidate() }
                if self.player?.isPlaying != true {
                    timer.invalidate()
                    if self.playingID == entry.id { self.playingID = nil }
                }
            }
        }
    }

    func delete(_ entry: HistoryStore.Entry) {
        if playingID == entry.id { player?.stop(); playingID = nil }
        HistoryStore.shared.trash(entry)
        entries.removeAll { $0.id == entry.id }
    }

    func retry(_ entry: HistoryStore.Entry) {
        guard let url = entry.wavURL, retryingID == nil else { return }
        retryingID = entry.id
        Task { @MainActor in
            _ = await retryHandler?(url)
            retryingID = nil
            reload()
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return f
    }()
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.filtered) { entry in
                        row(entry)
                    }
                    if model.filtered.isEmpty {
                        Text(model.entries.isEmpty ? "No dictations yet." : "No matches.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.top, 60)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 440, minHeight: 320)
        .onAppear { model.reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Button {
                    HistoryStore.shared.openInFinder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open the raw history folder in Finder")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcripts", text: $model.query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        }
        .padding(.horizontal, 16)
        .padding(.top, 34)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func row(_ entry: HistoryStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = entry.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if entry.isUnfinished {
                Text("Not transcribed yet - press Retry to hear it become words.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if entry.error != nil {
                // The raw error lives in the JSON record and the log - a
                // human reading this row needs the way out, not the trace.
                Text("Transcription didn't finish. Your audio is safe - press Retry.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("No words were heard in this one.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                chip(Self.day.string(from: entry.createdAt) + " · "
                    + Self.clock.string(from: entry.createdAt))
                if let duration = entry.duration {
                    chip(String(format: "%.0fs", duration.rounded(.up)))
                }
                Spacer()
                if entry.isUnfinished || (entry.text ?? "").isEmpty, entry.wavURL != nil {
                    actionButton(
                        model.retryingID == entry.id ? "hourglass" : "arrow.clockwise",
                        label: "Retry"
                    ) { model.retry(entry) }
                    .disabled(model.retryingID != nil)
                }
                if entry.wavURL != nil {
                    actionButton(
                        model.playingID == entry.id ? "stop.fill" : "play.fill",
                        label: model.playingID == entry.id ? "Stop" : "Play"
                    ) { model.togglePlay(entry) }
                }
                if let text = entry.text, !text.isEmpty {
                    actionButton(
                        model.copiedID == entry.id ? "checkmark" : "doc.on.doc",
                        label: model.copiedID == entry.id ? "Copied" : "Copy",
                        accent: true
                    ) { model.copy(entry) }
                }
                actionButton("trash", label: "Delete", destructive: true) {
                    model.delete(entry)
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1))
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func actionButton(
        _ symbol: String, label: String, accent: Bool = false, destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                accent
                    ? Color(red: 1.0, green: 0.62, blue: 0.11).opacity(0.22)
                    : .white.opacity(0.07),
                in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            destructive
                ? Color(red: 1.0, green: 0.45, blue: 0.40)
                : accent ? Color(red: 1.0, green: 0.72, blue: 0.35) : .primary)
    }
}
