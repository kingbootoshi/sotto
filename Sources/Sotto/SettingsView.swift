import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var onHotkeyChange: () -> Void
    var onModelChange: () -> Void

    @State private var hotkey = Preferences.shared.hotkey
    @State private var soundsEnabled = Preferences.shared.soundsEnabled
    @State private var soundPack = Preferences.shared.soundPack
    @State private var multilingual = Preferences.shared.useMultilingualModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Hotkey", selection: $hotkey) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .onChange(of: hotkey) { _, newValue in
                    Preferences.shared.hotkey = newValue
                    onHotkeyChange()
                }

                Picker("Model", selection: $multilingual) {
                    Text("Parakeet v2 — English, best accuracy").tag(false)
                    Text("Parakeet v3 — 25 languages").tag(true)
                }
                .onChange(of: multilingual) { _, newValue in
                    Preferences.shared.useMultilingualModel = newValue
                    onModelChange()
                }
            }

            Section("Sounds") {
                Toggle("Sound effects", isOn: $soundsEnabled)
                    .onChange(of: soundsEnabled) { _, newValue in
                        Preferences.shared.soundsEnabled = newValue
                    }
                Picker("Sound pack", selection: $soundPack) {
                    ForEach(SoundPack.allCases) { pack in
                        Text(pack.label).tag(pack)
                    }
                }
                .disabled(!soundsEnabled)
                .onChange(of: soundPack) { _, newValue in
                    Preferences.shared.soundPack = newValue
                    SoundPlayer.shared.play(.arrive)
                }
            }

            Section("App") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginError = nil
                        } catch {
                            loginError = "Launch at login needs the bundled Sotto.app: \(error.localizedDescription)"
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Open History Folder") {
                    HistoryStore.shared.openInFinder()
                }
            }

            Section {
                Text("Hold the hotkey, speak, release. The transcript pastes into whatever app you are in. Everything runs on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
