import SwiftUI

/// The Sonos library in the Now Playing tab: pick a group, click something, it starts there.
struct BrowseView: View {
    @ObservedObject var browser: MediaBrowser
    @ObservedObject var sonos: SonosController
    let close: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            header
            if browser.favorites.isEmpty, browser.sonosPlaylists.isEmpty, browser.spotifyPlaylists.isEmpty {
                placeholder
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        section("My Sonos", browser.favorites)
                        section("Sonos Playlists", browser.sonosPlaylists)
                        if !browser.spotifyPlaylists.isEmpty {
                            sectionHeader("Spotify Playlists")
                            ForEach(browser.spotifyPlaylists) { playlist in
                                row(id: "spotify:playlist:\(playlist.id)", title: playlist.name,
                                    subtitle: playlist.owner.isEmpty ? "\(playlist.trackCount) tracks" : "\(playlist.owner) · \(playlist.trackCount) tracks",
                                    artworkURL: playlist.imageURL) { done in
                                    browser.play(playlist, completion: done)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
            if let message = browser.message {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Play on")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
            Menu {
                ForEach(sonos.groups) { group in
                    Button(group.label) { browser.targetGroupID = group.id }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hifispeaker.fill").font(.system(size: 9))
                    Text(browser.targetGroup?.label ?? "No speakers")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            if browser.isLoading {
                ProgressView().controlSize(.mini)
            } else {
                iconButton("arrow.clockwise", help: "Reload") { browser.load(force: true) }
            }
            iconButton("xmark", help: "Close") { close() }
        }
    }

    private var placeholder: some View {
        Text(browser.isLoading ? "Reading the Sonos library…" : "Nothing in My Sonos yet. Star things in the Sonos app and they show up here.")
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.5))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [SonosItem]) -> some View {
        if !items.isEmpty {
            sectionHeader(title)
            ForEach(items) { item in
                row(id: item.id, title: item.title, subtitle: item.subtitle, artworkURL: item.artworkURL) { done in
                    browser.play(item, completion: done)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func row(id: String, title: String, subtitle: String, artworkURL: String, start: @escaping (@escaping (Bool) -> Void) -> Void) -> some View {
        let starting = browser.startingID == id
        return Button {
            start { started in if started { close() } }
        } label: {
            HStack(spacing: 8) {
                artwork(artworkURL)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if starting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(browser.startingID != nil)
    }

    private func artwork(_ url: String) -> some View {
        Group {
            if let url = URL(string: url), !url.absoluteString.isEmpty {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.1)
                    }
                }
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
