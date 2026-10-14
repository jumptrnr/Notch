import SwiftUI

struct NotchRootView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var media: MediaController
    @ObservedObject var sonos: SonosController
    @ObservedObject var browser: MediaBrowser
    @ObservedObject var lyrics: LyricsProvider
    @ObservedObject var shelf: ShelfModel
    @ObservedObject var codes: CodeWatcher
    @ObservedObject var accounts: MailAccountStore
    @ObservedObject var plugins: PluginRegistry
    @ObservedObject var textScale = TextScale.shared
    let openSettings: () -> Void

    /// Read live from `SMAppService` each time the context menu opens, so the toggle stays
    /// truthful if the login item is changed in System Settings.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { LaunchAtLogin.isEnabled },
            set: { LaunchAtLogin.setEnabled($0) }
        )
    }

    var body: some View {
        let size = state.isOpen ? state.openSize : state.closedSize
        ZStack(alignment: .top) {
            NotchShape(
                bottomRadius: state.isOpen ? 22 : 10,
                topRadius: state.isOpen ? 12 : 7
            )
            .fill(Color(nsColor: NSColor(calibratedWhite: 0, alpha: 1)))
            .overlay(alignment: .top) {
                if state.isOpen {
                    openContent
                        .transition(.opacity)
                } else {
                    closedContent
                }
            }
            .frame(width: size.width, height: size.height)
            .contextMenu {
                Button("Settings…", action: openSettings)
                Toggle("Copy Codes Automatically", isOn: $codes.autoCopy)
                Divider()
                Toggle("Launch at Login", isOn: launchAtLogin)
            }
        }
        .frame(width: state.windowSize.width, height: state.windowSize.height, alignment: .top)
        .onChange(of: state.isOpen) { _, open in
            if open { plugins.notchOpened() }
        }
        // A plug-in that was just disconnected takes its tab with it.
        .onChange(of: plugins.activeIDs) { _, ids in
            if case .plugin(let id) = state.selectedTab, !ids.contains(id) {
                state.selectedTab = .nowPlaying
            }
        }
    }

    // Collapsed: a subtle live indicator when music is playing.
    private var closedContent: some View {
        HStack {
            Spacer()
            if codes.hasUnseenCode {
                Image(systemName: "key.fill")
                    .font(.ui(10, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.trailing, 10)
                    // Draws the eye to the notch without the panel having to open itself.
                    .transition(.scale.combined(with: .opacity))
            } else if media.isPlaying {
                Image(systemName: "waveform")
                    .font(.ui(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.trailing, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private var openContent: some View {
        VStack(spacing: 10) {
            tabBar
            Group {
                switch state.selectedTab {
                case .nowPlaying:
                    NowPlayingView(media: media, lyrics: lyrics, sonos: sonos, browser: browser, showLyrics: $state.showLyrics, showSpeakers: $state.showSpeakers, showQueue: $state.showQueue, showBrowser: $state.showBrowser)
                case .codes:
                    CodesView(watcher: codes, accounts: accounts, openSettings: openSettings)
                case .shelf:
                    ShelfView(shelf: shelf)
                case .plugin(let id):
                    if let plugin = plugins.plugin(id) {
                        plugin.tabView
                    }
                }
            }
        }
        .padding(.top, state.closedSize.height + 6)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .foregroundStyle(.white)
        .frame(width: state.openSize.width, height: state.openSize.height, alignment: .top)
        // Fonts read the scale when a view is built, so a change rebuilds the whole panel.
        .id(textScale.value)
    }

    /// One track holding the tabs, the way a segmented control does, with Settings on the right
    /// so it needn't be found in the right-click menu. Plug-ins supply their own label: the
    /// Wind tab shows the wind.
    private var tabBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                tab(.nowPlaying) {
                    Label("Now Playing", systemImage: "waveform")
                }
                tab(.codes) {
                    Label("Codes", systemImage: "key.fill")
                    if codes.hasUnseenCode {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                    }
                }
                tab(.shelf) {
                    Label("Shelf", systemImage: "tray.fill")
                }
                ForEach(plugins.activeIDs, id: \.self) { id in
                    if let plugin = plugins.plugin(id) {
                        tab(.plugin(id)) { plugin.tabLabel }
                    }
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            Spacer(minLength: 0)
            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.ui(11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .frame(height: 22)
    }

    private func tab<Content: View>(_ value: NotchTab, @ViewBuilder label: () -> Content) -> some View {
        let selected = state.selectedTab == value
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { state.selectedTab = value }
            if value == .codes { codes.enterTab() }
        } label: {
            HStack(spacing: 4) { label() }
                .labelStyle(TabLabelStyle())
                .font(.ui(11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .white : .white.opacity(0.6))
                .padding(.horizontal, 9)
                .frame(height: 18)
                .background(Capsule().fill(Color.white.opacity(selected ? 0.18 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Icon then title, with the icon a touch smaller than the text so the row reads as words.
private struct TabLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.ui(10, weight: .semibold))
            configuration.title
        }
    }
}
