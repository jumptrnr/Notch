import SwiftUI

struct NowPlayingView: View {
    @ObservedObject var media: MediaController
    @ObservedObject var lyrics: LyricsProvider
    @ObservedObject var sonos: SonosController
    @ObservedObject var browser: MediaBrowser
    @Binding var showLyrics: Bool
    @Binding var showSpeakers: Bool
    @Binding var showBrowser: Bool

    var body: some View {
        if showBrowser, sonos.isEnabled {
            BrowseView(browser: browser, sonos: sonos, close: closeBrowser)
                .onAppear { browser.load() }
        } else if media.hasTrack {
            VStack(spacing: 10) {
                track
                ProgressBar(media: media)
                if showSpeakers, media.activeSource == .sonos {
                    SpeakersView(sonos: sonos)
                } else if showLyrics {
                    LyricsView(media: media, lyrics: lyrics)
                }
            }
            // The panel only makes sense for Sonos; stow it if what's showing moves elsewhere,
            // or the notch stays tall around nothing.
            .onChange(of: media.activeSource) { _, source in
                if source != .sonos, showSpeakers {
                    withAnimation(NotchState.toggle) { showSpeakers = false }
                }
            }
        } else {
            empty
        }
    }

    private func closeBrowser() {
        withAnimation(NotchState.toggle) { showBrowser = false }
    }

    /// Opens the Sonos library browser, to start something on a group from here. Rides above
    /// the skip-back button; the empty state offers it as a plain button.
    @ViewBuilder
    private var browseToggle: some View {
        if sonos.isEnabled {
            Button {
                withAnimation(NotchState.toggle) { showBrowser = true }
            } label: {
                Image(systemName: "music.note.list")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 22, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Browse Sonos library")
        }
    }

    private var track: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(media.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(media.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text(media.activeApp)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 0)
            controls
        }
    }

    /// A pair of separate notes. SF Symbols has no two-note glyph — `music.quarternote.3` is a
    /// trio — so the pair is composed from the single-note symbol, the second nudged up so the
    /// two don't read as one smudge at 9pt.
    private var noteIcon: some View {
        HStack(spacing: 1) {
            Image(systemName: "music.note")
            Image(systemName: "music.note")
                .offset(y: -1.5)
        }
        .font(.system(size: 9, weight: .medium))
    }

    /// How far the lyrics toggle rides above the play button. Just clears it, so the two read as
    /// one cluster rather than a stray button near the title.
    private static let lyricsToggleRise: CGFloat = -20

    /// Stowing the lyrics panel shrinks the notch back, so it animates with the same spring the
    /// panel uses to open and close.
    private var lyricsToggle: some View {
        Button {
            withAnimation(NotchState.toggle) {
                showLyrics.toggle()
                if showLyrics { showSpeakers = false }
            }
        } label: {
            noteIcon
                .foregroundStyle(.white.opacity(showLyrics ? 1 : 0.45))
                .frame(width: 22, height: 20)
                .background(
                    Circle().fill(Color.white.opacity(showLyrics ? 0.18 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(showLyrics ? "Hide lyrics" : "Show lyrics")
    }

    /// Opens the speakers panel: which rooms play along, and each one's volume. Only while a
    /// Sonos group is what's showing: the Spotify and local sources have no say over Sonos. Rides
    /// above the skip-forward button the way the lyrics toggle rides above play.
    @ViewBuilder
    private var speakersToggle: some View {
        if media.activeSource == .sonos, !sonos.rooms.isEmpty {
            Button {
                withAnimation(NotchState.toggle) {
                    showSpeakers.toggle()
                    if showSpeakers { showLyrics = false }
                }
            } label: {
                Image(systemName: "hifispeaker.2.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(showSpeakers ? 1 : 0.45))
                    .frame(width: 22, height: 20)
                    .background(
                        Circle().fill(Color.white.opacity(showSpeakers ? 0.18 : 0))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(showSpeakers ? "Hide speakers" : "Speakers and volume")
        }
    }

    private var empty: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .foregroundStyle(.white.opacity(0.5))
            Text("Nothing playing")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
            if sonos.isEnabled {
                Button("Browse Sonos…") {
                    withAnimation(NotchState.toggle) { showBrowser = true }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.14)))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 68)
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
        .frame(width: 68, height: 68)
        .clipShape(Rectangle())
    }

    private var controls: some View {
        HStack(spacing: 14) {
            controlButton("backward.fill") { media.previous() }
                .overlay(alignment: .top) {
                    browseToggle.offset(y: Self.lyricsToggleRise)
                }
            controlButton(media.isPlaying ? "pause.fill" : "play.fill", size: 18) { media.playPause() }
                // Floated over the play button rather than stacked above it: a VStack would push
                // play/pause down and leave it out of line with the two skip buttons.
                .overlay(alignment: .top) {
                    lyricsToggle.offset(y: Self.lyricsToggleRise)
                }
            controlButton("forward.fill") { media.next() }
                .overlay(alignment: .top) {
                    speakersToggle.offset(y: Self.lyricsToggleRise)
                }
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat = 14, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
