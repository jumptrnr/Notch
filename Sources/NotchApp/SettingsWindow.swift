import AppKit
import SwiftUI

/// Owns the single settings window. Kept separate from the notch panel because that panel is
/// borderless, non-activating and collapses on pointer exit — none of which suits a text form.
@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(spotify: SpotifyAuth, sonos: SonosController, plugins: PluginRegistry, accounts: MailAccountStore, watcher: CodeWatcher) {
        if let window {
            present(window)
            return
        }
        let view = SettingsView(spotify: spotify, sonos: sonos, plugins: plugins, accounts: accounts, watcher: watcher)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 1020),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Notch"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        present(window)
    }

    private func present(_ window: NSWindow) {
        // An accessory app isn't active by default, so the form couldn't take keystrokes without
        // explicitly activating first.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Spotify and Sonos on top, then each plug-in, mail accounts below.
private struct SettingsView: View {
    @ObservedObject var spotify: SpotifyAuth
    @ObservedObject var sonos: SonosController
    @ObservedObject var plugins: PluginRegistry
    @ObservedObject var accounts: MailAccountStore
    @ObservedObject var watcher: CodeWatcher

    var body: some View {
        VStack(spacing: 0) {
            NotchSettingsView()
                .padding(18)
            Divider()
            SpotifySettingsView(auth: spotify)
                .padding(18)
            Divider()
            SonosSettingsView(sonos: sonos)
                .padding(18)
            Divider()
            ForEach(plugins.plugins.map { $0.id }, id: \.self) { id in
                if let plugin = plugins.plugin(id) {
                    plugin.settingsView
                        .padding(18)
                    Divider()
                }
            }
            MailSettingsView(accounts: accounts, watcher: watcher)
        }
        .frame(width: 420)
    }
}

/// The panel itself: how large its text is drawn.
private struct NotchSettingsView: View {
    @ObservedObject var textScale = TextScale.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notch")
                .font(.headline)
            Picker("Text size", selection: $textScale.value) {
                ForEach(TextScale.options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.segmented)
            Text("The panel grows with the text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
