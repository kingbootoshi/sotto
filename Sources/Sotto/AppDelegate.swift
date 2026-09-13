import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

/// Accessory (menu-bar) apps launch with no main menu, and macOS routes
/// cmd-A/C/V/X/Z through the Edit menu's key equivalents - without this,
/// muscle-memory editing is dead in every window the app ever shows.
@MainActor
func installMainMenu() {
    let main = NSMenu()

    let fileHolder = NSMenuItem()
    main.addItem(fileHolder)
    let file = NSMenu(title: "File")
    file.addItem(
        withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w")
    fileHolder.submenu = file

    let editHolder = NSMenuItem()
    main.addItem(editHolder)
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(
        withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editHolder.submenu = edit

    NSApp.mainMenu = main
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = DictationController()
    private let hotkeys = HotkeyMonitor()
    private var settingsWindow: NSWindow?

    private let stateMenuItem = NSMenuItem(title: "Model: not loaded", action: nil, keyEquivalent: "")
    private let hintMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let recoverMenuItem = NSMenuItem(
        title: "Recover Unfinished Recordings", action: #selector(recoverUnfinished), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        Vocabulary.ensureFile()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        statusItem.menu = buildMenu()

        controller.onStateChange = { [weak self] state in
            if case .recording = state {
                self?.setIcon(recording: true)
            } else {
                self?.setIcon(recording: false)
            }
        }
        controller.engine.onStatusChange = { [weak self] status in
            self?.stateMenuItem.title = status.label
        }

        hotkeys.onDown = { [weak self] in Task { @MainActor in self?.controller.hotkeyDown() } }
        hotkeys.onUp = { [weak self] in Task { @MainActor in self?.controller.hotkeyUp() } }
        hotkeys.onEscape = { [weak self] in Task { @MainActor in self?.controller.escapePressed() } }
        hotkeys.start()

        promptForAccessibilityIfNeeded()
        refreshHint()
        prepareEngine()
    }

    private func prepareEngine() {
        Task {
            try? await controller.engine.prepare(version: Preferences.shared.modelVersion)
            // Unfinished WAVs (crash, force-quit, power loss) are transcribed
            // automatically as soon as the model is warm. No menu hunting.
            let recovered = await controller.recoverUnfinished()
            if recovered > 0 {
                NSLog("Sotto: auto-recovered \(recovered) unfinished recording(s)")
            }
            let pending = HistoryStore.shared.unfinishedRecordings().count
            recoverMenuItem.title = "Recover Unfinished Recordings (\(pending))"
            recoverMenuItem.isHidden = pending == 0
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        hintMenuItem.isEnabled = false
        stateMenuItem.isEnabled = false
        menu.addItem(hintMenuItem)
        menu.addItem(stateMenuItem)
        menu.addItem(.separator())

        recoverMenuItem.target = self
        recoverMenuItem.isHidden = true
        menu.addItem(recoverMenuItem)

        let historyItem = NSMenuItem(
            title: "History…", action: #selector(openHistory), keyEquivalent: "h")
        historyItem.image = NSImage(
            systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        historyItem.target = self
        menu.addItem(historyItem)

        let vocabularyItem = NSMenuItem(
            title: "Vocabulary…", action: #selector(openVocabulary), keyEquivalent: "")
        vocabularyItem.image = NSImage(
            systemSymbolName: "character.book.closed", accessibilityDescription: nil)
        vocabularyItem.target = self
        menu.addItem(vocabularyItem)

        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Sotto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        return menu
    }

    func refreshHint() {
        let key = Preferences.shared.hotkey.shortLabel
        hintMenuItem.title = "Tap \(key) to dictate, tap again to stop, Esc skips the paste"
    }

    private func setIcon(recording: Bool) {
        let image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "Sotto")
        if recording {
            // Same glyph, brand orange — recording reads as a color change,
            // not a different (pressed-looking) shape.
            let config = NSImage.SymbolConfiguration(paletteColors: [
                NSColor(red: 1.0, green: 0.62, blue: 0.11, alpha: 1.0)
            ])
            let tinted = image?.withSymbolConfiguration(config)
            tinted?.isTemplate = false
            statusItem.button?.image = tinted
        } else {
            image?.isTemplate = true
            statusItem.button?.image = image
        }
    }

    private func promptForAccessibilityIfNeeded() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSLog("Sotto: waiting for Accessibility trust (needed for the hotkey and paste)")
        }
    }

    @objc private func openVocabulary() {
        Vocabulary.ensureFile()
        NSWorkspace.shared.open(Vocabulary.fileURL)
    }

    @objc private func openHistory() {
        HistoryWindowController.shared.retryHandler = { [weak self] url in
            await self?.controller.retryTranscription(url: url) ?? false
        }
        HistoryWindowController.shared.show()
    }

    @objc private func recoverUnfinished() {
        Task {
            let count = await controller.recoverUnfinished()
            let pending = HistoryStore.shared.unfinishedRecordings().count
            recoverMenuItem.title = "Recover Unfinished Recordings (\(pending))"
            recoverMenuItem.isHidden = pending == 0
            NSLog("Sotto: recovered \(count) recordings")
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                onHotkeyChange: { [weak self] in self?.refreshHint() },
                onModelChange: { [weak self] in self?.prepareEngine() })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "Sotto Settings"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
