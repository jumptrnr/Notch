import AppKit
import Foundation

/// Now Playing from the Spotify or Music app running on this Mac, via AppleScript. (Apple
/// restricts the private MediaRemote framework to signed system apps, so scripting the player
/// apps is the reliable third-party path. First run prompts for Automation access.)
final class LocalPlayerSource {
    private let queue = DispatchQueue(label: "notch.media.applescript", qos: .userInitiated)

    func snapshot() async -> MediaSnapshot? {
        await withCheckedContinuation { continuation in
            queue.async {
                let raw = Self.run(Self.readScript) ?? ""
                continuation.resume(returning: Self.parse(raw))
            }
        }
    }

    /// `app` is the player the snapshot came from; with none showing, whichever is running.
    func control(_ command: String, app: String?) {
        let target = app ?? Self.runningPlayer()
        queue.async {
            _ = Self.run("tell application \"\(target)\" to \(command)")
        }
    }

    /// Pauses the Spotify app and returns once it has, so another player on the same account
    /// can start without Spotify stopping one of the two.
    func pauseSpotify() async {
        await withCheckedContinuation { continuation in
            queue.async {
                _ = Self.run("if application \"Spotify\" is running then tell application \"Spotify\" to pause")
                continuation.resume()
            }
        }
    }

    func seek(to seconds: Double, app: String?) {
        let target = app ?? Self.runningPlayer()
        queue.async {
            let value = String(format: "%.3f", seconds)
            _ = Self.run("tell application \"\(target)\" to set player position to \(value)")
        }
    }

    /// The Spotify app's current track as a playable Spotify track, so the speakers can pick it
    /// up. nil for anything else: a local file, an episode, an ad, no app.
    func spotifyTrack() async -> GeneratedTrack? {
        await withCheckedContinuation { continuation in
            queue.async {
                let raw = Self.run(Self.spotifyTrackScript) ?? ""
                let lines = raw.components(separatedBy: "\n")
                let prefix = "spotify:track:"
                guard lines.count >= 3, lines[0].hasPrefix(prefix) else {
                    continuation.resume(returning: nil)
                    return
                }
                let track = GeneratedTrack(id: String(lines[0].dropFirst(prefix.count)), name: lines[1], artist: lines[2],
                                           album: "", artworkURL: lines.count >= 4 ? lines[3] : "")
                continuation.resume(returning: track)
            }
        }
    }

    /// Output is linefeed-separated: track URI, title, artist, artwork URL.
    private static let spotifyTrackScript = """
    set lf to (ASCII character 10)
    if application "Spotify" is not running then return ""
    tell application "Spotify"
        try
            return (id of current track) & lf & (name of current track) & lf & (artist of current track) & lf & (artwork url of current track)
        end try
    end tell
    return ""
    """

    private static func runningPlayer() -> String {
        let apps = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }
        return apps.contains("Spotify") ? "Spotify" : "Music"
    }

    private static func parse(_ raw: String) -> MediaSnapshot? {
        let lines = raw.components(separatedBy: "\n")
        guard lines.count >= 4, !lines[0].isEmpty else { return nil }
        return MediaSnapshot(
            title: lines[1],
            artist: lines[2],
            isPlaying: lines[3] == "playing",
            artworkURL: lines.count >= 5 ? lines[4] : "",
            position: lines.count >= 6 ? number(lines[5]) : nil,
            duration: (lines.count >= 7 ? number(lines[6]) : nil) ?? 0,
            label: lines[0]
        )
    }

    /// AppleScript renders reals with the system decimal separator, which isn't always ".".
    private static func number(_ field: String) -> Double? {
        Double(field.replacingOccurrences(of: ",", with: "."))
    }

    private static func run(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prefers Spotify if it has a track, otherwise falls back to Music.
    /// Output is 7 linefeed-separated fields: app, title, artist, state, artworkURL, position, duration.
    /// Position and duration are both normalized to seconds (Spotify reports duration in milliseconds).
    private static let readScript = """
    set lf to (ASCII character 10)
    set out to ""
    if application "Spotify" is running then
        tell application "Spotify"
            try
                set pstate to player state as text
                if pstate is not "stopped" then
                    set out to "Spotify" & lf & (name of current track) & lf & (artist of current track) & lf & pstate & lf & (artwork url of current track) & lf & (player position as text) & lf & (((duration of current track) / 1000) as text)
                end if
            end try
        end tell
    end if
    if out is "" then
        if application "Music" is running then
            tell application "Music"
                try
                    if player state is not stopped then
                        set pstate to player state as text
                        set out to "Music" & lf & (name of current track) & lf & (artist of current track) & lf & pstate & lf & lf & (player position as text) & lf & ((duration of current track) as text)
                    end if
                end try
            end tell
        end if
    end if
    return out
    """
}
