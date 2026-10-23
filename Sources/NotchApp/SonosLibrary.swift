import Foundation

/// Something in the Sonos household's library that a group can start: a My Sonos favourite, a
/// Sonos playlist, or a Spotify playlist addressed through the account linked in the Sonos app.
struct SonosItem: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var artworkURL: String
    /// The transport URI, and the DIDL-Lite the speaker needs alongside it to resolve it.
    var uri: String
    var metadata: String
}

/// Browsing and starting. Any speaker serves the whole household's library over ContentDirectory,
/// and the same objects play on any group once handed to that group's coordinator.
extension SonosController {
    private static let contentDirectory = "/MediaServer/ContentDirectory/Control"
    private static let avTransport = "/MediaRenderer/AVTransport/Control"
    private static let didlNamespaces = #"xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/""#

    /// A speaker to ask. The one that answered last is the usual choice.
    private var librarySpeaker: String? { knownSpeaker ?? groups.first?.coordinatorIP }

    // MARK: Browsing

    /// My Sonos: what has been starred in the Sonos app, from any service.
    func favorites() async throws -> [SonosItem] {
        let (items, speaker) = try await browse("FV:2")
        return items.compactMap { fields in
            guard let title = fields["dc:title"], let uri = fields["res"], !uri.isEmpty else { return nil }
            return SonosItem(
                id: fields["id"] ?? uri,
                title: title,
                subtitle: fields["r:description"] ?? "",
                artworkURL: Self.absoluteArt(fields["upnp:albumArtURI"], speaker: speaker),
                uri: uri,
                // Favourites carry the metadata the original service wrote, escaped once more.
                metadata: fields["r:resMD"].map(Self.unescape) ?? ""
            )
        }
    }

    /// Playlists saved in the Sonos app itself.
    func sonosPlaylists() async throws -> [SonosItem] {
        let (items, speaker) = try await browse("SQ:")
        return items.compactMap { fields in
            guard let id = fields["id"], let title = fields["dc:title"], let uri = fields["res"], !uri.isEmpty else { return nil }
            let metadata = """
            <DIDL-Lite \(Self.didlNamespaces)><item id="\(Self.escape(id))" parentID="SQ:" restricted="true">\
            <dc:title>\(Self.escape(title))</dc:title><upnp:class>object.container.playlistContainer</upnp:class>\
            <desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">RINCON_AssociatedZPUDN</desc></item></DIDL-Lite>
            """
            return SonosItem(
                id: id, title: title, subtitle: "Sonos playlist",
                artworkURL: Self.absoluteArt(fields["upnp:albumArtURI"], speaker: speaker),
                uri: uri, metadata: metadata
            )
        }
    }

    /// A Spotify playlist as the speakers' own Spotify account sees it, so it starts without
    /// Spotify Connect or Premium. The container id and the service token are what the Sonos
    /// app writes for the same playlist.
    func spotifyPlaylistItem(id: String, name: String, owner: String, artworkURL: String) async throws -> SonosItem {
        let service = try await spotifyService()
        let objectID = "1006206cspotify%3aplaylist%3a\(id)"
        let metadata = """
        <DIDL-Lite \(Self.didlNamespaces)><item id="\(objectID)" parentID="0" restricted="true">\
        <dc:title>\(Self.escape(name))</dc:title><upnp:class>object.container.playlistContainer</upnp:class>\
        <desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">\(service.token)</desc></item></DIDL-Lite>
        """
        return SonosItem(
            id: "spotify:playlist:\(id)", title: name, subtitle: owner.isEmpty ? "Spotify" : "Spotify · \(owner)",
            artworkURL: artworkURL, uri: "x-rincon-cpcontainer:\(objectID)", metadata: metadata
        )
    }

    /// Spotify's radio for a track: the track first, then similar ones for as long as it plays,
    /// through the speakers' own Spotify login. It is a stream, so it can't be sought into, but
    /// Next works. The ids are what the Sonos app writes when it starts a track's radio.
    func spotifyTrackRadioItem(_ track: GeneratedTrack) async throws -> SonosItem {
        let service = try await spotifyService()
        let encoded = "spotify%3atrackRadio%3a\(track.id)"
        let metadata = """
        <DIDL-Lite \(Self.didlNamespaces)><item id="100c206c\(encoded)" parentID="0" restricted="true">\
        <dc:title>\(Self.escape(track.name)) Radio</dc:title><upnp:class>object.item.audioItem.audioBroadcast.#trackRadio</upnp:class>\
        <desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">\(service.token)</desc></item></DIDL-Lite>
        """
        return SonosItem(
            id: "spotify:trackRadio:\(track.id)", title: "\(track.name) Radio", subtitle: track.artist,
            artworkURL: track.artworkURL, uri: "x-sonosapi-radio:\(encoded)?sid=\(service.id)&flags=8300&sn=\(service.serial)", metadata: metadata
        )
    }

    /// Spotify on this household: its service number, which differs by region, the serial of
    /// the account linked in the Sonos app, and the token the two make. Sonos keeps the serial
    /// to itself, so it is read off a starred Spotify item, where the app wrote it as `sn=`.
    struct SpotifyService {
        var id: Int
        var serial: Int
        var token: String
    }

    func spotifyService() async throws -> SpotifyService {
        guard let ip = librarySpeaker else { throw SonosError.message("No Sonos speaker reachable.") }
        let xml = try await soap(ip: ip, service: "MusicServices", path: "/MusicServices/Control", action: "ListAvailableServices")
        let list = Self.text("AvailableServiceDescriptorList", in: xml).map(Self.unescape) ?? ""
        guard let regex = try? NSRegularExpression(pattern: #"<Service Id="(\d+)"[^>]*Name="Spotify""#),
              let match = regex.firstMatch(in: list, range: NSRange(list.startIndex..., in: list)),
              let range = Range(match.range(at: 1), in: list),
              let serviceID = Int(list[range])
        else { throw SonosError.message("Spotify isn't linked in the Sonos app.") }

        let (favourites, _) = try await browse("FV:2")
        guard let serialRegex = try? NSRegularExpression(pattern: #"[?&]sid=(\d+)&(?:amp;)?(?:[^&]*&(?:amp;)?)*sn=(\d+)"#) else {
            throw SonosError.message("Bad serial pattern.")
        }
        var serials: [Int: Int] = [:]
        for fields in favourites {
            for value in [fields["res"], fields["r:resMD"]].compactMap({ $0 }) {
                for found in serialRegex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
                    guard let sidRange = Range(found.range(at: 1), in: value), Int(value[sidRange]) == serviceID,
                          let snRange = Range(found.range(at: 2), in: value), let serial = Int(value[snRange]) else { continue }
                    serials[serial, default: 0] += 1
                }
            }
        }
        guard let serial = serials.max(by: { $0.value < $1.value })?.key else {
            throw SonosError.message("Star any Spotify item in the Sonos app first; Notch reads the account number from it.")
        }
        let number = serviceID * 256 + 7
        return SpotifyService(id: serviceID, serial: serial, token: "SA_RINCON\(number)_X_#Svc\(number)-0-Token")
    }

    /// Direct children of a container, as a dictionary of tag text per entry plus its id.
    private func browse(_ objectID: String) async throws -> (items: [[String: String]], speaker: String) {
        guard let ip = librarySpeaker else { throw SonosError.message("No Sonos speaker reachable.") }
        return try await browse(objectID, on: ip)
    }

    /// The same, from a given speaker: a queue lives on its group's coordinator.
    private func browse(_ objectID: String, on ip: String) async throws -> (items: [[String: String]], speaker: String) {
        let xml = try await soap(
            ip: ip, service: "ContentDirectory", path: Self.contentDirectory, action: "Browse",
            body: "<ObjectID>\(objectID)</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter>"
                + "<StartingIndex>0</StartingIndex><RequestedCount>200</RequestedCount><SortCriteria></SortCriteria>"
        )
        guard let didl = Self.text("Result", in: xml).map(Self.unescape) else { return ([], ip) }
        return (Self.parseEntries(didl), ip)
    }

    private nonisolated static func parseEntries(_ didl: String) -> [[String: String]] {
        guard let entryRegex = try? NSRegularExpression(pattern: #"<(item|container) id="([^"]*)"[^>]*>(.*?)</\1>"#, options: [.dotMatchesLineSeparators]),
              let tagRegex = try? NSRegularExpression(pattern: #"<([\w:]+)(?:\s[^>]*)?>([^<]*)</\1>"#)
        else { return [] }
        var entries: [[String: String]] = []
        for match in entryRegex.matches(in: didl, range: NSRange(didl.startIndex..., in: didl)) {
            guard let idRange = Range(match.range(at: 2), in: didl),
                  let bodyRange = Range(match.range(at: 3), in: didl) else { continue }
            let body = String(didl[bodyRange])
            var fields: [String: String] = ["id": unescape(String(didl[idRange]))]
            for tag in tagRegex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let nameRange = Range(tag.range(at: 1), in: body),
                      let valueRange = Range(tag.range(at: 2), in: body) else { continue }
                let name = String(body[nameRange])
                // First occurrence wins: an entry can carry several res elements.
                if fields[name] == nil { fields[name] = unescape(String(body[valueRange])) }
            }
            entries.append(fields)
        }
        return entries
    }

    private nonisolated static func absoluteArt(_ art: String?, speaker: String) -> String {
        guard let art, !art.isEmpty else { return "" }
        return art.hasPrefix("/") ? "http://\(speaker):1400\(art)" : art
    }

    // MARK: Queue

    /// Where the shown group is in its queue, and the queue itself. The position is read on
    /// every poll; the list only when the group changes, on demand, or every half minute, since
    /// a long queue is a sizeable browse.
    func refreshQueue(force: Bool = false) async {
        guard let group = activeGroup else {
            queue = []
            queueIndex = nil
            return
        }
        let ip = group.coordinatorIP
        do {
            async let position = soap(ip: ip, service: "AVTransport", path: Self.avTransport, action: "GetPositionInfo", body: "<InstanceID>0</InstanceID>")
            async let media = soap(ip: ip, service: "AVTransport", path: Self.avTransport, action: "GetMediaInfo", body: "<InstanceID>0</InstanceID>")
            let positionXML = try await position
            let mediaXML = try await media
            queueIsSource = (Self.text("CurrentURI", in: mediaXML) ?? "").hasPrefix("x-rincon-queue:")
            let track = Self.text("Track", in: positionXML).flatMap(Int.init)
            queueIndex = (track ?? 0) > 0 ? track : nil
            let stale = queueFetchedAt.map { Date().timeIntervalSince($0) > 30 } ?? true
            let moved = queueGroupID != group.id
            // A track number past the end of what was listed means the queue grew.
            let grew = (track ?? 0) > queue.count
            if force || stale || moved || grew {
                let (items, _) = try await browse("Q:0", on: ip)
                queue = items.enumerated().map { offset, fields in
                    SonosQueueItem(
                        index: offset + 1,
                        title: fields["dc:title"] ?? "",
                        artist: fields["dc:creator"] ?? "",
                        album: fields["upnp:album"] ?? "",
                        artworkURL: Self.absoluteArt(fields["upnp:albumArtURI"], speaker: ip)
                    )
                }
                queueFetchedAt = Date()
                queueGroupID = group.id
            }
        } catch {
            sonosLog.error("queue on \(group.label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Starting

    /// Hands the item to the group's coordinator and plays it. Streams (radio, line-in) go
    /// straight to the transport; everything else is loaded into the group's queue and the
    /// transport pointed at that, which is how the Sonos app starts a playlist or album.
    func play(_ item: SonosItem, on group: SonosGroup) async throws {
        remember(group)
        let ip = group.coordinatorIP
        let streamPrefixes = ["x-sonosapi-stream:", "x-sonosapi-radio:", "x-sonosapi-hls:", "x-rincon-stream:", "x-sonos-http:"]
        if streamPrefixes.contains(where: item.uri.hasPrefix) {
            _ = try await soap(
                ip: ip, service: "AVTransport", path: Self.avTransport, action: "SetAVTransportURI",
                body: "<InstanceID>0</InstanceID><CurrentURI>\(Self.escape(item.uri))</CurrentURI><CurrentURIMetaData>\(Self.escape(item.metadata))</CurrentURIMetaData>"
            )
        } else {
            _ = try await soap(ip: ip, service: "AVTransport", path: Self.avTransport, action: "RemoveAllTracksFromQueue", body: "<InstanceID>0</InstanceID>")
            _ = try await soap(
                ip: ip, service: "AVTransport", path: Self.avTransport, action: "AddURIToQueue",
                body: "<InstanceID>0</InstanceID><EnqueuedURI>\(Self.escape(item.uri))</EnqueuedURI><EnqueuedURIMetaData>\(Self.escape(item.metadata))</EnqueuedURIMetaData>"
                    + "<DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued><EnqueueAsNext>1</EnqueueAsNext>"
            )
            _ = try await soap(
                ip: ip, service: "AVTransport", path: Self.avTransport, action: "SetAVTransportURI",
                body: "<InstanceID>0</InstanceID><CurrentURI>x-rincon-queue:\(group.coordinatorUUID)#0</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
            )
        }
        _ = try await soap(ip: ip, service: "AVTransport", path: Self.avTransport, action: "Play", body: "<InstanceID>0</InstanceID><Speed>1</Speed>")
        sonosLog.notice("started \(item.title, privacy: .public) on \(group.label, privacy: .public)")
    }

    /// Loads Spotify tracks into the group's queue, one by one, and plays it: a playlist that
    /// exists nowhere but here, played through the account linked in the Sonos app.
    func play(tracks: [GeneratedTrack], named name: String, on group: SonosGroup) async throws {
        guard !tracks.isEmpty else { throw SonosError.message("No tracks to play.") }
        remember(group)
        let service = try await spotifyService()
        let ip = group.coordinatorIP
        _ = try await soap(ip: ip, service: "AVTransport", path: Self.avTransport, action: "RemoveAllTracksFromQueue", body: "<InstanceID>0</InstanceID>")
        for track in tracks {
            let encoded = "spotify%3atrack%3a\(track.id)"
            let uri = "x-sonos-spotify:\(encoded)?sid=\(service.id)&flags=8224&sn=\(service.serial)"
            let metadata = """
            <DIDL-Lite \(Self.didlNamespaces)><item id="00032020\(encoded)" parentID="-1" restricted="true">\
            <dc:title>\(Self.escape(track.name))</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class>\
            <desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">\(service.token)</desc></item></DIDL-Lite>
            """
            _ = try await soap(
                ip: ip, service: "AVTransport", path: Self.avTransport, action: "AddURIToQueue",
                body: "<InstanceID>0</InstanceID><EnqueuedURI>\(Self.escape(uri))</EnqueuedURI><EnqueuedURIMetaData>\(Self.escape(metadata))</EnqueuedURIMetaData>"
                    + "<DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued><EnqueueAsNext>0</EnqueueAsNext>"
            )
        }
        _ = try await soap(
            ip: ip, service: "AVTransport", path: Self.avTransport, action: "SetAVTransportURI",
            body: "<InstanceID>0</InstanceID><CurrentURI>x-rincon-queue:\(group.coordinatorUUID)#0</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
        )
        _ = try await soap(ip: ip, service: "AVTransport", path: Self.avTransport, action: "Play", body: "<InstanceID>0</InstanceID><Speed>1</Speed>")
        sonosLog.notice("started \(tracks.count) generated tracks (\(name, privacy: .public)) on \(group.label, privacy: .public)")
    }
}
