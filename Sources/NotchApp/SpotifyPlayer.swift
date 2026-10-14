import Foundation

/// The slice of the Spotify Web API the notch needs: playback state and transport controls.
/// It reports whatever device the account is playing on — Sonos, a phone, the desktop app —
/// which AppleScript can't see, since that only talks to the local Spotify app.
@MainActor
final class SpotifyPlayer {
    struct State {
        var title: String
        var artist: String
        var isPlaying: Bool
        var artworkURL: String
        /// Seconds.
        var position: Double
        var duration: Double
        var device: String
    }

    private let auth: SpotifyAuth

    /// Set from a 429's Retry-After; no request goes out before it. Shared by every player, since
    /// the limit is on the account's app, and kept across launches: a relaunch that asks again at
    /// once only earns another 429.
    private static var retryAfter: Date = {
        let stored = UserDefaults.standard.double(forKey: retryAfterKey)
        return stored > 0 ? Date(timeIntervalSince1970: stored) : .distantPast
    }() {
        didSet { UserDefaults.standard.set(retryAfter.timeIntervalSince1970, forKey: retryAfterKey) }
    }
    private static let retryAfterKey = "spotifyRetryAfter"

    init(auth: SpotifyAuth) {
        self.auth = auth
    }

    /// nil means nothing is playing: Spotify answers 204 when no device is active.
    func state() async throws -> State? {
        let (data, status) = try await send("GET", "me/player", query: "additional_types=track,episode")
        switch status {
        case 200:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let response = try decoder.decode(PlayerResponse.self, from: data)
            return Self.state(from: response)
        case 204:
            return nil
        default:
            throw SpotifyError.http(status)
        }
    }

    func play() async throws { try await command("PUT", "me/player/play") }
    func pause() async throws { try await command("PUT", "me/player/pause") }
    func next() async throws { try await command("POST", "me/player/next") }
    func previous() async throws { try await command("POST", "me/player/previous") }

    func seek(to seconds: Double) async throws {
        let ms = Int(max(seconds, 0) * 1000)
        try await command("PUT", "me/player/seek", query: "position_ms=\(ms)")
    }

    struct Playlist: Identifiable, Equatable {
        let id: String
        let name: String
        let owner: String
        let imageURL: String
        let trackCount: Int
    }

    /// The account's playlists, own and followed, newest first as Spotify orders them. Private
    /// ones need the playlist-read-private scope, granted at connect time; a connection made
    /// before that scope was asked for gets a 403 here and must be redone in Settings.
    func playlists() async throws -> [Playlist] {
        var out: [Playlist] = []
        var offset = 0
        while offset < 200 {
            let (data, status) = try await send("GET", "me/playlists", query: "limit=50&offset=\(offset)")
            switch status {
            case 200: break
            case 403: throw SpotifyError.message("Reconnect Spotify in Settings to allow listing playlists.")
            default: throw SpotifyError.http(status)
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let page = try decoder.decode(PlaylistPage.self, from: data)
            for item in page.items {
                guard let item else { continue }
                let image = item.images?.min { ($0.width ?? 0) < ($1.width ?? 0) }?.url ?? ""
                out.append(Playlist(id: item.id, name: item.name, owner: item.owner?.displayName ?? "", imageURL: image, trackCount: item.tracks?.total ?? 0))
            }
            if page.next == nil { break }
            offset += 50
        }
        return out
    }

    private struct PlaylistPage: Decodable {
        struct Owner: Decodable { let displayName: String? }
        struct Tracks: Decodable { let total: Int? }
        struct Item: Decodable {
            let id: String
            let name: String
            let owner: Owner?
            let images: [PlayerResponse.Image]?
            let tracks: Tracks?
        }
        /// Spotify leaves null entries for playlists it couldn't load.
        let items: [Item?]
        let next: String?
    }

    private func command(_ method: String, _ path: String, query: String? = nil) async throws {
        let (data, status) = try await send(method, path, query: query)
        switch status {
        case 200, 202, 204: return
        case 403:
            // 403 is also "restriction violated", e.g. pausing what is already paused.
            let error = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
            if error?.reason == "PREMIUM_REQUIRED" { throw SpotifyError.premiumRequired }
            throw SpotifyError.message(error?.message ?? "Spotify refused the command.")
        case 404: throw SpotifyError.message("No active Spotify device.")
        default: throw SpotifyError.http(status)
        }
    }

    private struct ErrorResponse: Decodable {
        struct Body: Decodable { let message: String?; let reason: String? }
        let error: Body
    }

    private func send(_ method: String, _ path: String, query: String? = nil) async throws -> (Data, Int) {
        guard Date() >= Self.retryAfter else { throw SpotifyError.rateLimited }
        let token = try await auth.validAccessToken()
        var urlString = "https://api.spotify.com/v1/" + path
        if let query { urlString += "?" + query }
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if method != "GET" {
            // Spotify wants a Content-Length even on bodiless PUT/POST.
            request.httpBody = Data()
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 {
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            guard let wait = header.flatMap(Double.init) else {
                spotifyLog.error("429 without a usable Retry-After (\(header ?? "none", privacy: .public))")
                throw SpotifyError.rateLimited
            }
            Self.retryAfter = Date().addingTimeInterval(wait)
            spotifyLog.error("rate-limited for \(Int(wait))s on \(path, privacy: .public)")
            throw SpotifyError.rateLimited
        }
        if status == 401 {
            auth.invalidateAccessToken()
        }
        return (data, status)
    }

    // MARK: Response shape

    private struct PlayerResponse: Decodable {
        struct Device: Decodable { let name: String? }
        struct Image: Decodable { let url: String; let width: Int? }
        struct Artist: Decodable { let name: String }
        struct Album: Decodable { let images: [Image]? }
        struct Show: Decodable { let name: String?; let publisher: String? }
        struct Item: Decodable {
            let name: String?
            let durationMs: Double?
            let artists: [Artist]?
            let album: Album?
            let show: Show?
            let images: [Image]?
        }
        let device: Device?
        let isPlaying: Bool?
        let progressMs: Double?
        let item: Item?
    }

    /// `item` is null during ads and in private sessions; that reads as "nothing playing".
    private static func state(from response: PlayerResponse) -> State? {
        guard let item = response.item, let title = item.name else { return nil }
        let artist: String
        if let artists = item.artists, !artists.isEmpty {
            artist = artists.map(\.name).joined(separator: ", ")
        } else {
            artist = item.show?.name ?? item.show?.publisher ?? ""
        }
        let images = item.album?.images ?? item.images ?? []
        // The notch shows art small; the ~300px rendition is plenty and a quarter of the 640.
        let art = images.min { abs(($0.width ?? 0) - 300) < abs(($1.width ?? 0) - 300) }
        return State(
            title: title,
            artist: artist,
            isPlaying: response.isPlaying ?? false,
            artworkURL: art?.url ?? "",
            position: (response.progressMs ?? 0) / 1000,
            duration: (item.durationMs ?? 0) / 1000,
            device: response.device?.name ?? ""
        )
    }
}
