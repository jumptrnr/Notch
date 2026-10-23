import Foundation

/// The library browser's state: what the household can play, which group to play it on, and
/// what is being started. Sonos favourites and playlists come from a speaker; Spotify playlists
/// from the connected account, started through the speakers' own Spotify login.
@MainActor
final class MediaBrowser: ObservableObject {
    @Published private(set) var favorites: [SonosItem] = []
    @Published private(set) var sonosPlaylists: [SonosItem] = []
    @Published private(set) var spotifyPlaylists: [SpotifyPlayer.Playlist] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    /// The item being started, for its spinner.
    @Published private(set) var startingID: String?
    /// Chosen in the browser's picker; otherwise the group that is showing, else the one last
    /// used here, else the first.
    @Published var targetGroupID: String? {
        didSet { if targetGroupID != oldValue, let targetGroup { sonos.remember(targetGroup) } }
    }

    let sonos: SonosController
    let spotify: SpotifyAuth
    /// Prompt-to-tracks through the playlist service; its results play through `playGenerated`.
    let generator = PlaylistGenerator()
    private let player: SpotifyPlayer
    private let media: MediaController
    /// The Spotify app on this Mac, read and paused when its music moves to the speakers.
    private let local = LocalPlayerSource()
    private var loadTask: Task<Void, Never>?
    private var loadedAt: Date?

    init(sonos: SonosController, spotify: SpotifyAuth, media: MediaController) {
        self.sonos = sonos
        self.spotify = spotify
        self.player = SpotifyPlayer(auth: spotify)
        self.media = media
    }

    /// A chosen group that has since changed (regrouped in the Sonos app) is followed through
    /// the room it was chosen by, its coordinator then; with that room gone it is no group at
    /// all, never some other one, so nothing starts where it wasn't asked to.
    var targetGroup: SonosGroup? {
        if let targetGroupID {
            return sonos.groups.first { $0.id == targetGroupID }
                ?? sonos.groups.first { $0.members.contains { $0.uuid == targetGroupID } }
        }
        return sonos.activeGroup ?? sonos.lastUsedGroup ?? sonos.groups.first
    }

    /// Lists are fetched when the browser opens and kept for five minutes; the refresh button
    /// forces it.
    func load(force: Bool = false) {
        guard loadTask == nil else { return }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 300 { return }
        isLoading = true
        message = nil
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil }
            guard let self else { return }
            let spotifyConnected = spotify.isConnected
            async let favorites = attempt { try await self.sonos.favorites() }
            async let playlists = attempt { try await self.sonos.sonosPlaylists() }
            async let spotifyPlaylists = attempt { spotifyConnected ? try await self.player.playlists() : [] }
            var failures: [String] = []
            switch await favorites {
            case .success(let items): self.favorites = items
            case .failure(let error): failures.append("Favourites: \(error.localizedDescription)")
            }
            switch await playlists {
            case .success(let items): self.sonosPlaylists = items
            case .failure(let error): failures.append("Sonos playlists: \(error.localizedDescription)")
            }
            switch await spotifyPlaylists {
            case .success(let items): self.spotifyPlaylists = items
            case .failure(let error): failures.append("Spotify: \(error.localizedDescription)")
            }
            message = failures.isEmpty ? nil : failures.joined(separator: " ")
            loadedAt = Date()
            isLoading = false
        }
    }

    func play(_ item: SonosItem, completion: @escaping (Bool) -> Void) {
        start(id: item.id, completion: completion) { item }
    }

    func play(_ playlist: SpotifyPlayer.Playlist, completion: @escaping (Bool) -> Void) {
        start(id: "spotify:playlist:\(playlist.id)", completion: completion) { [sonos] in
            try await sonos.spotifyPlaylistItem(id: playlist.id, name: playlist.name, owner: playlist.owner, artworkURL: playlist.imageURL)
        }
    }

    /// Starts what the generator produced on the chosen group.
    func playGenerated(completion: @escaping (Bool) -> Void) {
        guard startingID == nil else { return }
        guard let group = targetGroup else {
            message = "No Sonos group to play on."
            completion(false)
            return
        }
        let tracks = generator.tracks
        let name = generator.name
        startingID = "generated"
        message = nil
        Task { [weak self] in
            guard let self else { return }
            var started = false
            do {
                try await sonos.play(tracks: tracks, named: name, on: group)
                started = true
            } catch {
                message = error.localizedDescription
                sonosLog.error("start generated on \(group.label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            startingID = nil
            if started { media.refreshSoon() }
            completion(started)
        }
    }

    /// Moves what the Spotify app on this Mac is playing to `group` as that track's Spotify
    /// radio, through the account linked in the Sonos app: the track again from the top, then
    /// similar music rather than silence once it ends. The Mac is paused first:
    /// Spotify streams one player per account, and a speaker started while the Mac is still
    /// streaming is stopped a few seconds in. If the speakers then fail, the Mac plays on.
    func moveFromMac(to group: SonosGroup?) {
        guard startingID == nil else { return }
        guard let group else {
            message = "No Sonos group to play on."
            return
        }
        startingID = "mac"
        message = nil
        Task { [weak self] in
            guard let self else { return }
            defer { startingID = nil }
            guard let track = await local.spotifyTrack() else {
                message = "Spotify on this Mac isn't on a track the speakers can play."
                return
            }
            let wasPlaying = media.isPlaying
            await local.pauseSpotify()
            do {
                try await sonos.play(sonos.spotifyTrackRadioItem(track), on: group)
                sonosLog.notice("moved \(track.name, privacy: .public) from this Mac to \(group.label, privacy: .public)")
                media.refreshSoon()
            } catch {
                if wasPlaying { local.control("play", app: "Spotify") }
                message = error.localizedDescription
                sonosLog.error("move to \(group.label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func start(id: String, completion: @escaping (Bool) -> Void, resolve: @escaping @MainActor () async throws -> SonosItem) {
        guard startingID == nil else { return }
        guard let group = targetGroup else {
            message = "No Sonos group to play on."
            completion(false)
            return
        }
        startingID = id
        message = nil
        Task { [weak self] in
            guard let self else { return }
            var started = false
            do {
                let item = try await resolve()
                try await sonos.play(item, on: group)
                started = true
            } catch {
                message = error.localizedDescription
                sonosLog.error("start on \(group.label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            startingID = nil
            if started { media.refreshSoon() }
            completion(started)
        }
    }

    private func attempt<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
}
