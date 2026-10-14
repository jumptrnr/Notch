import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsProvider
    @ObservedObject var sonos: SonosController
    @ObservedObject var browser: MediaBrowser
    @Binding var showLyrics: Bool
    @Binding var showSpeakers: Bool
    @Binding var showQueue: Bool
    @Binding var showBrowser: Bool

    var body: some View {
        if showBrowser, sonos.isEnabled {
            BrowseView(browser: browser, sonos: sonos, generator: browser.generator, close: closeBrowser, openQueue: openQueue)
                .onAppear { browser.load() }
        } else if media.hasTrack {
            VStack(spacing: 6) {
                track
                ProgressBar(media: media)
                if showSpeakers, sonos.activeGroup != nil {
                    SpeakersView(sonos: sonos)
                } else if showQueue, media.activeSource == .sonos {
                    QueueView(sonos: sonos)
                } else if showLyrics {
                    LyricsView(media: media, lyrics: lyrics)
                }
                footer
            }
            // The panels only make sense for Sonos; stow them if what's showing moves elsewhere,
            // or the notch stays tall around nothing. The speakers panel also serves a Spotify
            // session on the speakers, so it goes by whether there is a group rather than the source.
            .onChange(of: media.activeSource) { _, source in
                if source != .sonos, showQueue {
                    withAnimation(NotchState.toggle) { showQueue = false }
                }
            }
            .onChange(of: sonos.activeGroup == nil) { _, gone in
                if gone, showSpeakers {
                    withAnimation(NotchState.toggle) { showSpeakers = false }
                }
            }
        } else {
            QuickStartView(browser: browser, sonos: sonos, openBrowser: openBrowser)
        }
    }

    private func openBrowser() {
        withAnimation(NotchState.toggle) { showBrowser = true }
    }

    private func closeBrowser() {
        withAnimation(NotchState.toggle) { showBrowser = false }
    }

    /// After starting a list from the browser: the queue is where it went.
    private func openQueue() {
        withAnimation(NotchState.toggle) {
            showBrowser = false
            showLyrics = false
            showSpeakers = false
            showQueue = true
        }
    }

    private var track: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                Text(media.title)
                    .font(.ui(13, weight: .semibold))
                    .lineLimit(1)
                Text(media.artist)
                    .font(.ui(11))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            controls
        }
    }

    private var artwork: some View {
        Group {
            if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    /// Skip either side of a white disc, so the row has one focal point.
    private var controls: some View {
        HStack(spacing: 8) {
            skipButton("backward.fill") { media.previous() }
            Button {
                media.playPause()
            } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .font(.ui(14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(media.isPlaying ? "Pause" : "Play")
            skipButton("forward.fill") { media.next() }
        }
    }

    private func skipButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ui(13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Where the music is coming out, on the left; the lyrics and library toggles on the right.
    private var footer: some View {
        HStack(spacing: 6) {
            output
            Spacer(minLength: 0)
            if media.activeSource == .sonos {
                toggle("list.number", on: showQueue, help: showQueue ? "Hide queue" : "Queue") {
                    withAnimation(NotchState.toggle) {
                        showQueue.toggle()
                        if showQueue {
                            showLyrics = false
                            showSpeakers = false
                        }
                    }
                }
            }
            toggle("text.quote", on: showLyrics, help: showLyrics ? "Hide lyrics" : "Lyrics") {
                withAnimation(NotchState.toggle) {
                    showLyrics.toggle()
                    if showLyrics {
                        showSpeakers = false
                        showQueue = false
                    }
                }
            }
            if sonos.isEnabled {
                toggle("list.bullet", on: false, help: "Browse Sonos library", action: openBrowser)
            }
        }
        .frame(height: 20)
    }

    /// On Sonos speakers, whether started from the Sonos app or as a Spotify Connect session,
    /// the chip names the rooms and opens the speakers panel to change them; other outputs have
    /// nothing to pick, so it just names the app.
    @ViewBuilder
    private var output: some View {
        if let group = sonos.activeGroup, media.activeSource == .sonos || media.activeSource == .spotifyAPI {
            let label = sonos.groups.first { $0.id == group.id }?.label ?? group.label
            Button {
                withAnimation(NotchState.toggle) {
                    showSpeakers.toggle()
                    if showSpeakers {
                        showLyrics = false
                        showQueue = false
                    }
                }
            } label: {
                Chip(icon: "hifispeaker.fill", text: label, detail: media.activeSource == .sonos ? "Sonos" : "Spotify",
                     chevron: showSpeakers ? "chevron.up" : "chevron.down", filled: showSpeakers)
            }
            .buttonStyle(.plain)
            .help(showSpeakers ? "Hide speakers" : "Speakers and volume")
        } else {
            Chip(icon: "music.note", text: media.activeApp)
        }
    }

    private func toggle(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ui(10, weight: .medium))
                .foregroundStyle(.white.opacity(on ? 1 : 0.5))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(on ? 0.18 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The Now Playing tab with nothing to show: the first few My Sonos items as tiles, so starting
/// music is one click, and the group they'd start on. Without Sonos it is just the message.
struct QuickStartView: View {
    @ObservedObject var browser: MediaBrowser
    @ObservedObject var sonos: SonosController
    let openBrowser: () -> Void

    private static let tiles = 5

    var body: some View {
        if sonos.isEnabled {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("Nothing playing")
                        .font(.ui(12, weight: .semibold))
                    Text(caption)
                        .font(.ui(9))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    OutputPicker(sonos: sonos, selection: $browser.targetGroupID, current: browser.targetGroup)
                }
                .frame(height: 18)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(browser.favorites.prefix(Self.tiles)) { item in
                        LibraryTile(title: item.title, subtitle: item.subtitle, artworkURL: item.artworkURL, size: 58,
                                    starting: browser.startingID == item.id, disabled: browser.startingID != nil) {
                            browser.play(item) { _ in }
                        }
                    }
                    browseAll
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear { browser.load() }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .foregroundStyle(.white.opacity(0.5))
                Text("Nothing playing")
                    .font(.ui(12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, minHeight: 68)
        }
    }

    private var caption: String {
        if browser.favorites.isEmpty {
            return browser.isLoading ? "Reading the Sonos library…" : "Star things in the Sonos app to start them here"
        }
        return "Pick something from My Sonos"
    }

    private var browseAll: some View {
        Button(action: openBrowser) {
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: "list.bullet")
                    .font(.ui(16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 58, height: 58)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
                Text("Browse all")
                    .font(.ui(9, weight: .semibold))
                Text(browser.favorites.isEmpty ? "My Sonos" : "\(browser.favorites.count) in My Sonos")
                    .font(.ui(8))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(width: 58, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
