import AppKit

/// Hold-to-talk hotkey via global flagsChanged monitoring, plus Escape.
/// Requires Accessibility trust for global monitors and event posting.
final class HotkeyMonitor {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onEscape: (() -> Void)?

    private var monitors: [Any] = []
    private var pressed = false

    private enum KeyCode {
        static let fn: UInt16 = 63
        static let rightCommand: UInt16 = 54
        static let rightOption: UInt16 = 61
        static let rightControl: UInt16 = 62
        static let escape: UInt16 = 53
    }

    func start() {
        stop()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlags(event)
        }) { monitors.append(m) }
        monitors.append(
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlags(event)
                return event
            } as Any)
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == KeyCode.escape { self?.onEscape?() }
        }) { monitors.append(m) }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        pressed = false
    }

    private func handleFlags(_ event: NSEvent) {
        let down: Bool
        switch Preferences.shared.hotkey {
        case .fn:
            guard event.keyCode == KeyCode.fn else { return }
            down = event.modifierFlags.contains(.function)
        case .rightCommand:
            guard event.keyCode == KeyCode.rightCommand else { return }
            down = event.modifierFlags.contains(.command)
        case .rightOption:
            guard event.keyCode == KeyCode.rightOption else { return }
            down = event.modifierFlags.contains(.option)
        case .rightControl:
            guard event.keyCode == KeyCode.rightControl else { return }
            down = event.modifierFlags.contains(.control)
        }
        guard down != pressed else { return }
        pressed = down
        down ? onDown?() : onUp?()
    }
}

enum Paster {
    /// Puts the transcript on the pasteboard immediately — the fail-safe
    /// layer. The transcript stays on the clipboard: apps may read
    /// NSPasteboard well after the event posts, so restoring the previous
    /// contents on a timer intermittently pastes stale text — and keeping it
    /// means the words survive even if the target app refuses the paste.
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Synthesizes Cmd-V into the frontmost app. Call only after copy(_:).
    /// Returns false when Accessibility trust is missing and no event was
    /// sent. `done` fires after the whole event sequence has posted - the
    /// delivery queue must not let a later take touch the pasteboard before
    /// then.
    @discardableResult
    static func sendCmdV(done: @escaping () -> Void = {}) -> Bool {
        guard AXIsProcessTrusted() else {
            done()
            return false
        }

        // Small settle delay: in toggle mode the stop tap's own modifier
        // events are still in flight when transcription finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let cmd: UInt16 = 55, v: UInt16 = 9
            let sequence: [(UInt16, Bool, CGEventFlags)] = [
                (cmd, true, .maskCommand),
                (v, true, .maskCommand),
                (v, false, .maskCommand),
                (cmd, false, []),
            ]
            for (key, down, flags) in sequence {
                let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
                usleep(8000)
            }
            done()
        }
        return true
    }
}
