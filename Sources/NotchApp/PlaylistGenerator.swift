import Foundation
import OSLog

let playlistLog = Logger(subsystem: "com.robin.notch", category: "playlist")

/// One Spotify track the playlist service found for a prompt.
struct GeneratedTrack: Identifiable, Equatable {
    var id: String
    var name: String
    var artist: String
    var album: String
    var artworkURL: String
}

/// Turns a prompt into tracks through the playlist app's generate route, which streams its
/// progress as server-sent events: the AI's suggestions first, then each song as Spotify
/// confirms it, then the finished list. The route is open; a key in
/// `~/Library/Application Support/Notch/playlist-generate-key` is sent as `X-Generate-Key` and
/// earns the larger daily allowance the server grants trusted clients.
@MainActor
final class PlaylistGenerator: ObservableObject {
    enum Phase: Equatable {
        case idle, generating, complete, failed
    }

    static let endpoint = URL(string: "https://play.lysne.com/api/generate-playlist")!
    static let songCount = 20
    private static let keyFile = "playlist-generate-key"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var prompt = ""
    @Published private(set) var name = ""
    @Published private(set) var status = ""
    @Published private(set) var tracks: [GeneratedTrack] = []
    /// How many songs the AI proposed; the found count climbs toward it.
    @Published private(set) var expected = 0
    @Published private(set) var error: String?

    private var task: Task<Void, Never>?

    func generate(_ prompt: String) {
        reset()
        self.prompt = prompt
        phase = .generating
        status = "Asking for songs…"
        task = Task { await run(prompt) }
    }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        prompt = ""
        name = ""
        status = ""
        tracks = []
        expected = 0
        error = nil
    }

    private func run(_ prompt: String) async {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = SecretFile.read(Self.keyFile) {
            request.setValue(key, forHTTPHeaderField: "X-Generate-Key")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["prompt": prompt, "songCount": Self.songCount])
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw GenerateError.message("No answer from the playlist service.") }
            if http.statusCode != 200 {
                var body = Data()
                for try await byte in bytes { body.append(byte) }
                let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                let reason = json?["error"] as? String ?? "The playlist service answered \(http.statusCode)."
                throw GenerateError.message(reason)
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let data = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                try handle(event)
                if phase != .generating { return }
            }
            throw GenerateError.message("The playlist service stopped before finishing.")
        } catch is CancellationError {
        } catch {
            phase = .failed
            self.error = error.localizedDescription
            playlistLog.error("generate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(_ event: [String: Any]) throws {
        switch event["type"] as? String {
        case "status":
            status = event["message"] as? String ?? status
        case "raw_suggestions":
            name = event["name"] as? String ?? name
            expected = event["totalSongs"] as? Int ?? expected
            status = "Checking \(expected) songs on Spotify…"
        case "song_accepted":
            if let track = Self.track(event["track"]) {
                tracks.append(track)
            }
        case "complete":
            let playlist = event["playlist"] as? [String: Any]
            name = playlist?["name"] as? String ?? name
            let final = (playlist?["tracks"] as? [Any])?.compactMap(Self.track) ?? []
            if !final.isEmpty { tracks = final }
            status = "\(tracks.count) songs"
            phase = .complete
            playlistLog.notice("generated \(self.tracks.count) tracks for \(self.prompt, privacy: .public)")
        case "timeout":
            throw GenerateError.message(event["message"] as? String ?? "The playlist service took too long.")
        case "error":
            throw GenerateError.message(event["error"] as? String ?? "The playlist service failed.")
        default:
            break
        }
    }

    private static func track(_ value: Any?) -> GeneratedTrack? {
        guard let fields = value as? [String: Any],
              let id = fields["id"] as? String,
              let name = fields["name"] as? String else { return nil }
        let artists = (fields["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let album = fields["album"] as? [String: Any]
        let images = album?["images"] as? [[String: Any]] ?? []
        return GeneratedTrack(
            id: id, name: name,
            artist: artists.joined(separator: ", "),
            album: album?["name"] as? String ?? "",
            artworkURL: images.first?["url"] as? String ?? ""
        )
    }
}

enum GenerateError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
