import AppKit
import SwiftUI

// Workbench for overlay design iteration (`Sotto designpreview`). Renders all
// five candidate pill designs on the real desktop, each across the three
// phases, with live waveform motion. Screenshot, pick, wire into Overlay.

enum OverlayDesign: Int, CaseIterable, Identifiable {
    case classicGlass = 1  // refined current: glass capsule, orange wave
    case minimalDark = 2   // solid near-black, no border, quiet
    case ringPulse = 3     // glass with animated orange gradient rim
    case siriMirror = 4    // center-mirrored waveform, icon-first
    case breathingGlow = 5 // glass with soft breathing orange outer glow

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .classicGlass: return "1 · Classic Glass"
        case .minimalDark: return "2 · Minimal Dark"
        case .ringPulse: return "3 · Ring Pulse"
        case .siriMirror: return "4 · Mirror Wave"
        case .breathingGlow: return "5 · Breathing Glow"
        }
    }
}

let sottoOrange = Color(red: 1.0, green: 0.62, blue: 0.11)
let sottoGold = Color(red: 1.0, green: 0.8, blue: 0.35)

/// Smooth fake speech levels for the workbench and idle animation.
func syntheticLevels(t: Double, count: Int = 22) -> [Float] {
    (0..<count).map { i in
        let x = Double(i)
        let v = 0.42 + 0.34 * sin(t * 5.1 + x * 0.9) * sin(t * 2.3 + x * 0.35)
            + 0.18 * sin(t * 9.7 + x * 1.7)
        return Float(max(0.06, min(1.0, v)))
    }
}

struct DesignWave: View {
    let levels: [Float]
    let mirrored: Bool
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 26

    var body: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(LinearGradient(
                        colors: [sottoOrange, sottoGold],
                        startPoint: .bottom, endPoint: .top))
                    .frame(width: barWidth, height: max(barWidth, CGFloat(levels[i]) * maxHeight))
                    .frame(maxHeight: .infinity, alignment: mirrored ? .center : .bottom)
            }
        }
        .frame(height: maxHeight)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

struct DesignPill: View {
    let design: OverlayDesign
    let phase: OverlayModel.Phase
    let levels: [Float]
    let t: Double

    var body: some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(minWidth: 200, maxWidth: 460)
            .background(background)
            .overlay(rim)
            .shadow(color: shadowColor, radius: shadowRadius, y: 6)
    }

    @ViewBuilder private var content: some View {
        HStack(spacing: 11) {
            switch phase {
            case .listening:
                DesignWave(levels: levels, mirrored: design == .siriMirror)
                if design != .siriMirror {
                    Text("Listening")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.85))
                }
            case .transcribing:
                // Shimmer sweep: three dots pulsing in sequence
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(sottoOrange)
                            .frame(width: 7, height: 7)
                            .opacity(0.35 + 0.65 * pow(sin(t * 4 - Double(i) * 0.9), 2))
                    }
                }
                Text("Transcribing")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.85))
            case .done(let text):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(sottoOrange)
                Text(text)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder private var background: some View {
        switch design {
        case .minimalDark:
            Capsule().fill(Color.black.opacity(0.78))
        default:
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color.black.opacity(0.22))
            }
        }
    }

    @ViewBuilder private var rim: some View {
        switch design {
        case .minimalDark:
            EmptyView()
        case .ringPulse:
            Capsule().strokeBorder(
                AngularGradient(
                    colors: [sottoOrange.opacity(0.9), sottoGold.opacity(0.15),
                             sottoOrange.opacity(0.9)],
                    center: .center, angle: .degrees(t * 120)),
                lineWidth: 1.5)
        default:
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.3), .white.opacity(0.05)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
        }
    }

    private var shadowColor: Color {
        if design == .breathingGlow, case .listening = phase {
            return sottoOrange.opacity(0.35 + 0.25 * sin(t * 2.4))
        }
        return .black.opacity(0.3)
    }

    private var shadowRadius: CGFloat {
        if design == .breathingGlow, case .listening = phase {
            return 18 + 6 * sin(t * 2.4)
        }
        return 16
    }
}

struct DesignPreviewSheet: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let levels = syntheticLevels(t: t)
            VStack(alignment: .leading, spacing: 22) {
                ForEach(OverlayDesign.allCases) { design in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(design.label)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 3)
                        HStack(spacing: 16) {
                            DesignPill(design: design, phase: .listening, levels: levels, t: t)
                            DesignPill(design: design, phase: .transcribing, levels: levels, t: t)
                            DesignPill(design: design, phase: .done("Hello, hello."), levels: levels, t: t)
                        }
                    }
                }
            }
            .padding(40)
        }
    }
}

@MainActor
func runDesignPreview() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 1240, height: 640),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = NSHostingView(rootView: DesignPreviewSheet())
    if let screen = NSScreen.main {
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - 620, y: f.midY - 320))
    }
    panel.orderFrontRegardless()
    app.run()
}
