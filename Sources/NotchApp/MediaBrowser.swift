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
    /// Chosen in the browser's picker; otherwise the group that is showing, else the first.
    @Published var targetGroupID: String?

    let sonos: SonosController
    let spotify: SpotifyAuth
    private let player: SpotifyPlayer
    private let media: MediaController
    private var loadTask: Task<Void, Never>?
    private var loadedAt: Date?

    init(sonos: SonosController, spotify: SpotifyAuth, media: MediaController) {
        self.sonos = sonos
        self.spotify = spotify
        self.player = SpotifyPlayer(auth: spotify)
        self.media = media
    }

    var targetGroup: SonosGroup? {
        sonos.groups.first { $0.id == targetGroupID } ?? sonos.activeGroup ?? sonos.groups.first
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
