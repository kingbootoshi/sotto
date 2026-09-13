import AppKit
import SwiftUI

/// The comet shoots at the mouse position captured at the stop tap - the
/// microsecond the hotkey ends the dictation, not when the flight fires.
/// Ballistic: no mid-flight chasing - the hand moves on immediately while
/// transcription and the charge run, so only the tap position is intent.
private struct FlightOrbView: View {
    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: [
                        OverlayView.gold, OverlayView.orange,
                        Color(red: 0.7, green: 0.36, blue: 0),
                    ]),
                    center: .init(x: 0.38, y: 0.32), startRadius: 2, endRadius: 26))
            .frame(width: 42, height: 42)
            .shadow(color: OverlayView.orange.opacity(0.55), radius: 12)
            .shadow(color: OverlayView.orange.opacity(0.25), radius: 30)
    }
}

private struct SplashRingView: View {
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(OverlayView.gold, lineWidth: 2)
            .frame(width: 10, height: 10)
            .scaleEffect(expanded ? 5 : 0.4)
            .opacity(expanded ? 0 : 0.95)
            .onAppear {
                withAnimation(.easeOut(duration: 0.45)) { expanded = true }
            }
    }
}

/// The Streak launch, chosen from scripts/launch-variants.html at 1.0×:
/// 110ms slingshot pull-back along the firing line, then a 260ms cubic
/// ease-out shot that stretches into a light streak mid-flight. Blooms a
/// splash ring at the frozen landing point.
/// Each flight is self-contained (own panel, own timer): rapid takes may
/// have several comets airborne at once.
@MainActor
final class CometFlightController {

    private static func makePanel(size: CGFloat) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    /// Completion fires exactly once, at arrival. `aim` is the mouse
    /// position captured at the stop tap - ballistic, never re-read.
    func fly(from start: CGPoint, aim: CGPoint, onArrive: @escaping () -> Void) {
        // Panel is oversized so the rotated streak never clips: 42pt orb
        // stretched 3.6× on its axis ≈ 152pt diagonal.
        let panelSize: CGFloat = 170
        let panel = Self.makePanel(size: panelSize)
        let host = NSHostingView(rootView: FlightOrbView().frame(width: panelSize, height: panelSize))
        host.wantsLayer = true
        panel.contentView = host

        let dir = atan2(aim.y - start.y, aim.x - start.x)
        let pullDur = 0.110, flightDur = 0.260
        let pullDist: CGFloat = 14

        func place(at point: CGPoint, scale: CGFloat, stretch: CGFloat) {
            panel.setFrame(
                NSRect(
                    x: point.x - panelSize / 2, y: point.y - panelSize / 2,
                    width: panelSize, height: panelSize),
                display: true)
            if let layer = host.layer {
                layer.position = CGPoint(x: panelSize / 2, y: panelSize / 2)
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer.setAffineTransform(
                    CGAffineTransform(rotationAngle: dir).scaledBy(x: scale * stretch, y: scale))
            }
        }

        place(at: start, scale: 1, stretch: 1)
        panel.orderFrontRegardless()

        let startedAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { timer in
            Task { @MainActor in
                let elapsed = CACurrentMediaTime() - startedAt
                if elapsed < pullDur {
                    // Anticipation: drag backward along the firing line.
                    let p = elapsed / pullDur
                    let d = pullDist * CGFloat(min(p / 0.8, 1))
                    place(
                        at: CGPoint(x: start.x - cos(dir) * d, y: start.y - sin(dir) * d),
                        scale: 1 + 0.12 * CGFloat(p), stretch: 1)
                } else if elapsed < pullDur + flightDur {
                    let raw = (elapsed - pullDur) / flightDur
                    let t = CGFloat(1 - pow(1 - raw, 3))
                    let mid = CGFloat(1 - abs(raw - 0.5) * 2)
                    place(
                        at: CGPoint(
                            x: start.x + (aim.x - start.x) * t,
                            y: start.y + (aim.y - start.y) * t),
                        scale: 1 - 0.55 * t, stretch: 1 + 2.6 * mid)
                } else {
                    timer.invalidate()
                    panel.orderOut(nil)
                    self.splash(at: aim)
                    onArrive()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func splash(at point: CGPoint) {
        let panel = Self.makePanel(size: 90)
        panel.contentView = NSHostingView(rootView: SplashRingView().frame(width: 90, height: 90))
        panel.setFrame(
            NSRect(x: point.x - 45, y: point.y - 45, width: 90, height: 90), display: true)
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            panel.orderOut(nil)
        }
    }
}
