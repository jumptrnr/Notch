import Combine
import SwiftUI

/// A tab that only some users have. Each plug-in brings its own settings section and its own
/// tab, and stays hidden until it is set up there (a key pasted, a switch turned on), so a
/// user without it never sees it. Add one to the list in `AppDelegate` and nothing else.
@MainActor
protocol NotchPlugin: AnyObject {
    /// Stable identity for the tab; also what the logs call it.
    var id: String { get }
    /// Tab label. Short: the tab bar is 440 points wide and already holds three.
    var title: String { get }
    /// Whether the tab is shown. Re-read whenever `changes` fires.
    var isConfigured: Bool { get }
    /// Fires on anything the tab bar or the tab should redraw for. An `ObservableObject`'s
    /// `objectWillChange` is exactly that.
    var changes: AnyPublisher<Void, Never> { get }
    var settingsView: AnyView { get }
    var tabView: AnyView { get }
    /// The notch just expanded. Refresh here if the data is stale; the panel is shut most of the
    /// time and nothing should be fetched for it then.
    func notchOpened()
}

/// The installed plug-ins, in tab order. Republishes each one's changes so the tab bar and the
/// settings window follow a plug-in becoming configured.
@MainActor
final class PluginRegistry: ObservableObject {
    let plugins: [any NotchPlugin]
    private var subscriptions: [AnyCancellable] = []

    init(plugins: [any NotchPlugin]) {
        self.plugins = plugins
        for plugin in plugins {
            plugin.changes
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &subscriptions)
        }
    }

    var active: [any NotchPlugin] { plugins.filter { $0.isConfigured } }
    var activeIDs: [String] { active.map { $0.id } }

    func plugin(_ id: String) -> (any NotchPlugin)? {
        plugins.first { $0.id == id }
    }

    func notchOpened() {
        for plugin in active { plugin.notchOpened() }
    }
}
