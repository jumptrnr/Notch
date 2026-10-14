import SwiftUI

/// The Sonos library in the Now Playing tab: search, a filter, a grid of tiles; click one and it
/// starts on the chosen group.
struct BrowseView: View {
    @ObservedObject var browser: MediaBrowser
    @ObservedObject var sonos: SonosController
    @ObservedObject var generator: PlaylistGenerator
    let close: () -> Void
    let openQueue: () -> Void

    @State private var query = ""
    @State private var filter: Filter = .all
    /// The room picker is out in place of the library, as the Sonos app sheets it over the list.
    @State private var showRooms = false

    enum Filter: String, CaseIterable {
        case all = "All"
        case favorites = "My Sonos"
        case playlists = "Sonos playlists"
        case spotify = "Spotify"
    }

    private struct Entry: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var artworkURL: String
        var filter: Filter
        var start: (@escaping (Bool) -> Void) -> Void
    }

    private static let columns = 5
    private static let tile: CGFloat = 72

    private var entries: [Entry] {
        browser.favorites.map { item in
            Entry(id: item.id, title: item.title, subtitle: item.subtitle.isEmpty ? "My Sonos" : item.subtitle,
                  artworkURL: item.artworkURL, filter: .favorites) { done in browser.play(item, completion: done) }
        }
        + browser.sonosPlaylists.map { item in
            Entry(id: item.id, title: item.title, subtitle: item.subtitle.isEmpty ? "Sonos playlist" : item.subtitle,
                  artworkURL: item.artworkURL, filter: .playlists) { done in browser.play(item, completion: done) }
        }
        + browser.spotifyPlaylists.map { playlist in
            Entry(id: "spotify:playlist:\(playlist.id)", title: playlist.name,
                  subtitle: playlist.owner.isEmpty ? "Spotify · \(playlist.trackCount) tracks" : "\(playlist.owner) · \(playlist.trackCount) tracks",
                  artworkURL: playlist.imageURL, filter: .spotify) { done in browser.play(playlist, completion: done) }
        }
    }

    /// Spotify only earns a chip once the account's playlists are listed.
    private var filters: [Filter] {
        browser.spotifyPlaylists.isEmpty ? [.all, .favorites, .playlists] : Filter.allCases
    }

    private var shown: [Entry] {
        let active = filters.contains(filter) ? filter : .all
        let needle = query.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            (active == .all || entry.filter == active)
                && (needle.isEmpty || entry.title.localizedCaseInsensitiveContains(needle)
                    || entry.subtitle.localizedCaseInsensitiveContains(needle))
        }
    }

    /// A prompt worth sending: a few words, not a letter or two typed on the way to a title.
    private var promptable: String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 ? trimmed : nil
    }

    var body: some View {
        VStack(spacing: 6) {
            header
            if showRooms {
                rooms
            } else if generator.phase != .idle {
                GeneratedPanel(generator: generator, browser: browser, openQueue: openQueue)
            } else {
                if promptable != nil {
                    generateRow
                }
                chips
                if entries.isEmpty {
                    placeholder(browser.isLoading ? "Reading the Sonos library…" : "Nothing in My Sonos yet. Star things in the Sonos app and they show up here.")
                } else if shown.isEmpty {
                    placeholder("Nothing matches “\(query)”")
                } else {
                    grid
                }
            }
            if let message = browser.message {
                Text(message)
                    .font(.ui(9))
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            iconButton("chevron.left", help: "Back") { close() }
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.ui(9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                TextField("Search, or describe a playlist to make", text: $query)
                    .textFieldStyle(.plain)
                    .font(.ui(10))
                    .foregroundStyle(.white)
                    .onSubmit(generate)
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            if browser.isLoading {
                ProgressView().controlSize(.mini)
            } else {
                iconButton("arrow.clockwise", help: "Reload") { browser.load(force: true) }
            }
            Button {
                withAnimation(NotchState.toggle) { showRooms.toggle() }
            } label: {
                Chip(icon: "hifispeaker.fill", text: browser.targetGroup?.label ?? "No speakers",
                     chevron: showRooms ? "chevron.up" : "chevron.down", filled: showRooms)
            }
            .buttonStyle(.plain)
            .help(showRooms ? "Back to the library" : "Choose the rooms to play on")
        }
        .frame(height: 22)
    }

    /// Which rooms the next thing starts on: the chosen group's rooms ticked, the rest a tick
    /// away, and the name of any room elsewhere a way to start there instead.
    private var rooms: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("PLAY ON")
                    .font(.ui(8, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.white.opacity(0.5))
                Text("Tick the rooms that should play together")
                    .font(.ui(9))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    withAnimation(NotchState.toggle) { showRooms = false }
                } label: {
                    Chip(icon: "checkmark", text: "Done", filled: true)
                }
                .buttonStyle(.plain)
            }
            .frame(height: 18)
            ScrollView(.vertical) {
                RoomList(sonos: sonos, group: browser.targetGroup,
                         select: { browser.targetGroupID = $0.id },
                         regrouped: { browser.targetGroupID = $0 })
                    .padding(.trailing, 2)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func generate() {
        guard let prompt = promptable, generator.phase == .idle else { return }
        generator.generate(prompt)
    }

    /// Offered whenever there's a prompt in the field, whether or not it also matches something.
    private var generateRow: some View {
        Button(action: generate) {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                    .font(.ui(9, weight: .semibold))
                Text("Make a playlist from “\(promptable ?? query)”")
                    .font(.ui(10, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("Return")
                    .font(.ui(8, weight: .medium))
                    .opacity(0.45)
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ask the playlist service for songs matching this")
    }

    private var chips: some View {
        HStack(spacing: 4) {
            ForEach(filters, id: \.self) { candidate in
                let selected = candidate == (filters.contains(filter) ? filter : .all)
                Button {
                    filter = candidate
                } label: {
                    Text(candidate.rawValue)
                        .font(.ui(9, weight: selected ? .semibold : .medium))
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                        .padding(.horizontal, 8)
                        .frame(height: 16)
                        .background(Capsule().fill(Color.white.opacity(selected ? 0.18 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Text("\(shown.count) items")
                .font(.ui(8))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(height: 18)
    }

    private var grid: some View {
        ScrollView(.vertical) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(Self.tile), spacing: 11), count: Self.columns),
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(shown) { entry in
                    LibraryTile(title: entry.title, subtitle: entry.subtitle, artworkURL: entry.artworkURL, size: Self.tile,
                                starting: browser.startingID == entry.id, disabled: browser.startingID != nil) {
                        entry.start { started in if started { close() } }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.ui(11))
            .foregroundStyle(.white.opacity(0.5))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ui(10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// What the generator has so far: the name once the AI has answered, each song as Spotify
/// confirms it, and Play once the list is final. Discarding goes back to the library.
private struct GeneratedPanel: View {
    @ObservedObject var generator: PlaylistGenerator
    @ObservedObject var browser: MediaBrowser
    let openQueue: () -> Void

    private var starting: Bool { browser.startingID == "generated" }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(generator.name.isEmpty ? "Making a playlist…" : generator.name)
                        .font(.ui(11, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.ui(9))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if generator.phase == .generating || starting {
                    ProgressView().controlSize(.mini)
                }
                if generator.phase == .complete {
                    Button {
                        browser.playGenerated { started in
                            if started {
                                openQueue()
                                generator.reset()
                            }
                        }
                    } label: {
                        Chip(icon: "play.fill", text: "Play on \(browser.targetGroup?.label ?? "…")", filled: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(browser.startingID != nil || generator.tracks.isEmpty)
                }
                Button {
                    generator.reset()
                } label: {
                    Image(systemName: "xmark")
                        .font(.ui(10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(generator.phase == .generating ? "Stop" : "Discard")
            }
            .frame(height: 26)
            if generator.phase == .failed, let error = generator.error {
                Text(error)
                    .font(.ui(9))
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(Array(generator.tracks.enumerated()), id: \.element.id) { index, track in
                        row(track, number: index + 1)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var subtitle: String {
        switch generator.phase {
        case .generating:
            if generator.expected > 0 {
                return "\(generator.tracks.count) of \(generator.expected) found · \(generator.status)"
            }
            return generator.status
        case .complete:
            return "\(generator.tracks.count) songs for “\(generator.prompt)”"
        case .failed:
            return "Couldn't make “\(generator.prompt)”"
        case .idle:
            return ""
        }
    }

    private func row(_ track: GeneratedTrack, number: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.ui(9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 16, alignment: .trailing)
            ZStack {
                Color.white.opacity(0.1)
                if let url = URL(string: track.artworkURL), !track.artworkURL.isEmpty {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        }
                    }
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            Text(track.name)
                .font(.ui(10, weight: .medium))
                .lineLimit(1)
            Text(track.artist)
                .font(.ui(9))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 24)
    }
}
