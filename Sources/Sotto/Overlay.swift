import AppKit
import SwiftUI

@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case listening
        case transcribing
        case done(String)
        case error(String)
    }

    @Published var phase: Phase = .listening
    @Published var levels: [Float] = Array(repeating: 0, count: 26)
    /// true = the pill has merged into the comet orb (processing/charging).
    @Published var isOrb = false
    /// true while the orb is charging right before launch.
    @Published var charging = false

    func pushLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(min(1, level))
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: levels.count)
    }
}

/// Snake + Glow: middle-size glass capsule with one continuous line drawing
/// itself around the rim while its tail erases behind (Tron style), centered
/// orange waveform while listening, pulsing dots while transcribing.
/// Animations are Core Animation (repeatForever), not TimelineView: macOS
/// throttles TimelineView ticks in non-activating panels, and CA renders the
/// loop on the window server for near-zero CPU.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    static let orange = Color(red: 1.0, green: 0.62, blue: 0.11)
    static let gold = Color(red: 1.0, green: 0.8, blue: 0.35)

    var body: some View {
        HStack(spacing: 11) {
            switch model.phase {
            case .listening:
                WaveformView(levels: model.levels)
                Text("Listening")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.88))
            case .transcribing:
                PulsingDots()
                Text("Transcribing")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.88))
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Self.orange)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(3)
                    .frame(maxWidth: 440, alignment: .leading)
            }
        }
        // Merge: contents suck into the center while the shell contracts.
        .opacity(model.isOrb ? 0 : 1)
        .scaleEffect(model.isOrb ? 0.2 : 1)
        .padding(.horizontal, model.isOrb ? 0 : 21)
        .padding(.vertical, model.isOrb ? 0 : 11)
        // minWidth without maxWidth: the pill hugs its content — a bare
        // maxWidth would greedily expand into the fixed 620pt panel.
        .frame(minWidth: model.isOrb ? 0 : 210, minHeight: model.isOrb ? 0 : 46)
        .frame(width: model.isOrb ? 42 : nil, height: model.isOrb ? 42 : nil)
        .background(
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                    .opacity(model.isOrb ? 0 : 1)
                Capsule().fill(Color.black.opacity(0.26))
                    .opacity(model.isOrb ? 0 : 1)
                Capsule()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Self.gold, Self.orange, Color(red: 0.7, green: 0.36, blue: 0),
                            ]),
                            center: .init(x: 0.38, y: 0.32), startRadius: 2, endRadius: 26))
                    .opacity(model.isOrb ? 1 : 0)
            })
        .overlay(RingPulseRim().opacity(model.isOrb ? 0 : 1))
        .shadow(
            color: model.isOrb ? Self.orange.opacity(0.55) : .black.opacity(0.32),
            radius: model.isOrb ? 14 : 20, y: model.isOrb ? 0 : 8)
        .shadow(
            color: Self.orange.opacity(model.isOrb ? 0.25 : 0), radius: 34)
        .scaleEffect(model.charging ? 1.2 : 1)
        .brightness(model.charging ? 0.25 : 0)
        .animation(
            model.charging
                ? .easeIn(duration: 0.24).repeatForever(autoreverses: true)
                : .spring(response: 0.24, dampingFraction: 0.7),
            value: model.charging)
        .animation(.spring(response: 0.26, dampingFraction: 0.72), value: model.isOrb)
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The rim light: two continuous lines 180° apart gliding the same
/// direction (Tron/snake, twin parallel) — when one rides the top edge the
/// other rides the bottom — each with a soft glow halo underneath. Chosen
/// from scripts/rim-variants5.html, variant 1 (2.25s lap, 18% lines).
/// trimmedPath fractions are arc-length based, so the lines move at
/// constant speed and turn the capsule corners crisply.
private struct SnakeShape: Shape {
    var phase: CGFloat
    var length: CGFloat = 0.18

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let track = Capsule().path(in: rect.insetBy(dx: 1.25, dy: 1.25))
        var path = Path()
        for offset: CGFloat in [0, 0.5] {
            let head = (phase + offset).truncatingRemainder(dividingBy: 1)
            let end = head + length
            if end <= 1 {
                path.addPath(track.trimmedPath(from: head, to: end))
            } else {
                path.addPath(track.trimmedPath(from: head, to: 1))
                path.addPath(track.trimmedPath(from: 0, to: end - 1))
            }
        }
        return path
    }
}

private struct RingPulseRim: View {
    @State private var phase: CGFloat = 0

    private static let stroke = LinearGradient(
        colors: [OverlayView.orange, OverlayView.gold],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        ZStack {
            SnakeShape(phase: phase)
                .stroke(OverlayView.orange.opacity(0.55),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .blur(radius: 3)
            SnakeShape(phase: phase)
                .stroke(Self.stroke,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 2.25).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

private struct PulsingDots: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(OverlayView.orange)
                    .frame(width: 7, height: 7)
                    .opacity(pulsing ? 1 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.17),
                        value: pulsing)
            }
        }
        .onAppear { pulsing = true }
    }
}

struct WaveformView: View {
    let levels: [Float]

    private static let gradient = LinearGradient(
        colors: [OverlayView.orange, OverlayView.gold],
        startPoint: .bottom, endPoint: .top)

    var body: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(Self.gradient)
                    .frame(width: 3, height: max(3.5, CGFloat(levels[index]) * 26))
                    .frame(height: 26, alignment: .center)
            }
        }
        .frame(height: 26)
        .animation(.linear(duration: 0.07), value: levels)
    }
}

/// Borderless, non-activating, click-through glass panel at bottom center of
/// the active screen. Never steals focus from the app being dictated into.
@MainActor
final class OverlayPanelController {
    let model = OverlayModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
    }

    func show(phase: OverlayModel.Phase) {
        hideWork?.cancel()
        hideWork = nil
        model.phase = phase
        model.isOrb = false
        model.charging = false
        layout()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    func update(phase: OverlayModel.Phase) {
        model.phase = phase
    }

    /// The comet merge: contents suck inward, shell contracts into the orb.
    func mergeToOrb() {
        model.phase = .transcribing
        model.isOrb = true
    }

    /// Screen center of the orb (= panel center; the view is centered).
    var orbCenter: CGPoint {
        CGPoint(x: panel.frame.midX, y: panel.frame.midY)
    }

    /// Instant removal at launch: the flight panel takes over the orb.
    func vanish() {
        hideWork?.cancel()
        hideWork = nil
        panel.orderOut(nil)
        panel.alphaValue = 0
        model.resetLevels()
        model.isOrb = false
        model.charging = false
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.22
                    self.panel.animator().alphaValue = 0
                },
                completionHandler: {
                    Task { @MainActor in
                        self.panel.orderOut(nil)
                        self.model.resetLevels()
                    }
                })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Fixed generous frame: the pill/orb morph animates inside SwiftUI, so
    /// the panel itself never needs to resize mid-animation.
    private func layout() {
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: 620, height: 170)
        let frame = screen.visibleFrame
        panel.setFrame(
            NSRect(
                x: frame.midX - size.width / 2,
                y: frame.minY + 46,
                width: size.width,
                height: size.height),
            display: true)
    }
}
