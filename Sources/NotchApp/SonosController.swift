import Foundation
import OSLog

let sonosLog = Logger(subsystem: "com.robin.notch", category: "sonos")

/// A visible Sonos room: one speaker, or the primary of a stereo pair / home-theatre set.
struct SonosRoom: Identifiable, Equatable {
    var id: String { uuid }
    var uuid: String
    var ip: String
    var name: String
}

/// One entry of a group's queue.
struct SonosQueueItem: Identifiable, Equatable {
    /// 1-based, as the speaker numbers them.
    var index: Int
    var id: Int { index }
    var title: String
    var artist: String
    var album: String
    var artworkURL: String
}

/// One Sonos group: the rooms playing in sync. Only the coordinator carries transport state;
/// the others report `x-rincon:<coordinator>` and no metadata, so it is the one to poll and command.
struct SonosGroup: Identifiable, Equatable {
    var id: String { coordinatorUUID }
    var coordinatorUUID: String
    var coordinatorIP: String
    var name: String
    var members: [SonosRoom]

    var label: String { members.count > 1 ? "\(name) + \(members.count - 1)" : name }
}

/// Reads and controls Sonos speakers over their local UPnP API, so music started from the Sonos
/// app shows up. Spotify's own API never sees those sessions: the speaker streams the service
/// directly. One SSDP probe finds any speaker; its zone-group topology then lists every group.
@MainActor
final class SonosController: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { scan() }
        }
    }
    @Published private(set) var groups: [SonosGroup] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanMessage: String?

    private static let enabledKey = "sonosEnabled"
    private static let knownSpeakerKey = "sonosKnownSpeaker"
    private static let lastUsedRoomsKey = "sonosLastUsedRooms"

    /// Any reachable speaker's IP, good for fetching topology without another SSDP round.
    private(set) var knownSpeaker: String? {
        didSet { UserDefaults.standard.set(knownSpeaker, forKey: Self.knownSpeakerKey) }
    }
    /// UUIDs of the rooms last played on or grouped from here, streaming room first. With
    /// nothing playing, these are the speakers the notch and the browser start on.
    private var lastUsedRooms: [String] = [] {
        didSet { UserDefaults.standard.set(lastUsedRooms, forKey: Self.lastUsedRoomsKey) }
    }
    /// Whether the last-used rooms that have drifted apart since are still to be put back
    /// together. The first play of a launch does that; a grouping edit made here first cancels it.
    private var regroupPending = true
    private var topologyRefreshedAt = Date.distantPast
    private var scanTask: Task<Void, Never>?
    /// The group currently shown in the notch; transport commands and grouping changes go here.
    @Published private(set) var activeGroup: SonosGroup?

    /// Volume (0–100) and mute per room, keyed by room UUID, for the rooms in the shown group.
    @Published private(set) var volumes: [String: Int] = [:]
    @Published private(set) var muted: Set<String> = []
    /// Sonos's own group volume, which scales every member together. Nil for a lone room.
    @Published private(set) var groupVolume: Int?
    /// Set by the speakers panel. Volume is read on each poll only while it is showing, since
    /// that is three extra requests per room every two seconds.
    var wantsVolumes = false
    /// The shown group's queue, read only while the queue panel is out.
    var wantsQueue = false
    @Published var queue: [SonosQueueItem] = []
    /// 1-based position of the playing item in `queue`.
    @Published var queueIndex: Int?
    /// False when the transport is on a stream rather than the queue, so the list is not what's heard.
    @Published var queueIsSource = true
    var queueFetchedAt: Date?
    var queueGroupID: String?
    /// Rooms whose volume was just set here; polls leave them alone until the speaker has
    /// applied the change, so a slider doesn't jump back under the cursor.
    private var volumeHoldUntil: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private var queued: [String: @MainActor () async throws -> Void] = [:]
    /// The shown group's last good reading, and how many polls in a row have failed since.
    private var lastActiveReading: (groupID: String, snapshot: MediaSnapshot)?
    private var activeReadFailures = 0
    private static let readFailuresTolerated = 3
    /// The last grouping edit; the next one waits for it.
    private var groupingTail: Task<Void, Never>?

    /// Every visible room on the network, for the speakers menu.
    var rooms: [SonosRoom] {
        groups.flatMap(\.members).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Rooms in the shown group as the latest topology has them (`activeGroup` itself is a
    /// snapshot from the last poll and lags a just-made grouping change).
    var activeMembers: [SonosRoom] {
        groups.first { $0.id == activeGroup?.id }?.members ?? activeGroup?.members ?? []
    }

    /// The group holding the most of the last-used rooms, the one with their streaming room on
    /// a tie. Nil before anything has been played here, or once those rooms are all gone.
    var lastUsedGroup: SonosGroup? {
        guard let coordinator = lastUsedRooms.first else { return nil }
        let used = Set(lastUsedRooms)
        func score(_ group: SonosGroup) -> (Int, Int) {
            (group.members.filter { used.contains($0.uuid) }.count, group.members.contains { $0.uuid == coordinator } ? 1 : 0)
        }
        guard let best = groups.max(by: { score($0) < score($1) }), score(best).0 > 0 else { return nil }
        return best
    }

    /// On the first play of a launch on the last-used speakers, pulls back in the rooms that have
    /// left them since (split off in the Sonos app, or by the speakers themselves). A room now
    /// playing something else is left where it is. Returns `group` as it then stands.
    func regroupLastUsed(into group: SonosGroup) async -> SonosGroup {
        guard regroupPending else { return group }
        regroupPending = false
        let group = current(group)
        guard group.id == lastUsedGroup?.id else { return group }
        let missing = lastUsedRooms
            .filter { uuid in !group.members.contains { $0.uuid == uuid } }
            .compactMap { uuid in rooms.first { $0.uuid == uuid } }
        guard !missing.isEmpty else { return group }
        var coordinator = group.id
        for room in missing {
            if let home = groups.first(where: { $0.members.contains { $0.uuid == room.uuid } }), await isPlaying(home) {
                sonosLog.notice("not regrouping \(room.name, privacy: .public): \(home.label, privacy: .public) is playing")
                continue
            }
            coordinator = await setGrouped(room, true, in: groups.first { $0.id == coordinator } ?? group) ?? coordinator
        }
        return groups.first { $0.id == coordinator } ?? group
    }

    private func isPlaying(_ group: SonosGroup) async -> Bool {
        let xml = try? await soap(ip: group.coordinatorIP, service: "AVTransport", path: "/MediaRenderer/AVTransport/Control", action: "GetTransportInfo", body: "<InstanceID>0</InstanceID>")
        let state = xml.flatMap { Self.text("CurrentTransportState", in: $0) }
        return state == "PLAYING" || state == "TRANSITIONING"
    }

    /// Notes `group` as the speakers in use, for the next launch.
    func remember(_ group: SonosGroup) {
        // Picking the drifted-apart group before the first play mustn't forget the rooms that
        // play will bring back.
        if regroupPending, group.id == lastUsedGroup?.id { return }
        let rooms = [group.coordinatorUUID] + group.members.map(\.uuid).filter { $0 != group.coordinatorUUID }
        guard rooms != lastUsedRooms else { return }
        lastUsedRooms = rooms
        sonosLog.notice("last used: \(group.label, privacy: .public)")
    }

    /// Reads are polled, so they give up quickly.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config)
    }()

    /// Changes get longer: a speaker regrouping, or fetching a cloud playlist to queue, can take
    /// several seconds, and one abandoned at 2s may still land, half-done.
    private let writeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    init() {
        // Off until switched on in Settings: the first scan triggers macOS's Local Network prompt,
        // which users without Sonos shouldn't see.
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        knownSpeaker = UserDefaults.standard.string(forKey: Self.knownSpeakerKey)
        lastUsedRooms = UserDefaults.standard.stringArray(forKey: Self.lastUsedRoomsKey) ?? []
        if isEnabled { scan() }
    }

    // MARK: Discovery

    /// SSDP for one speaker, then that speaker's zone-group state for all of them. The speaker
    /// that answered last time is tried as well: SSDP needs multicast, which the local-network
    /// permission prompt blocks until it is answered and some Wi-Fi setups drop entirely.
    func scan() {
        guard scanTask == nil else { return }
        isScanning = true
        scanMessage = nil
        scanTask = Task { [weak self] in
            defer { self?.scanTask = nil }
            guard let self else { return }
            var candidates = await Task.detached(priority: .utility) { Self.ssdpDiscover() }.value
            if let knownSpeaker, !candidates.contains(knownSpeaker) { candidates.append(knownSpeaker) }
            var reached = false
            for ip in candidates {
                if await refreshTopology(from: ip) {
                    knownSpeaker = ip
                    reached = true
                    break
                }
            }
            if !reached {
                // The rooms stay as last seen: one missed answer shouldn't make Sonos vanish
                // mid-song. Reads of an unreachable group fail on their own.
                scanMessage = "No Sonos speakers answered. Check that this Mac is on the same network and that Notch is allowed to find local devices in System Settings › Privacy & Security › Local Network."
            } else if groups.isEmpty {
                scanMessage = "A speaker answered but reported no groups."
            }
            isScanning = false
        }
    }

    @discardableResult
    private func refreshTopology(from ip: String) async -> Bool {
        do {
            let xml = try await soap(ip: ip, service: "ZoneGroupTopology", path: "/ZoneGroupTopology/Control", action: "GetZoneGroupState")
            guard let state = Self.text("ZoneGroupState", in: xml).map(Self.unescape) else {
                throw SonosError.message("No zone group state in reply.")
            }
            let parsed = Self.parseGroups(state)
            if parsed != groups {
                groups = parsed
                sonosLog.notice("topology: \(parsed.map(\.label).joined(separator: ", "), privacy: .public)")
            }
            topologyRefreshedAt = Date()
            return true
        } catch {
            sonosLog.error("topology from \(ip, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Grouping changes whenever someone drags rooms together in the Sonos app, so the topology
    /// is re-read periodically from a known speaker. SSDP runs again only if that speaker is gone.
    private func refreshTopologyIfStale() async {
        guard Date().timeIntervalSince(topologyRefreshedAt) > 30 else { return }
        if let knownSpeaker, await refreshTopology(from: knownSpeaker) { return }
        scan()
    }

    // MARK: Reading

    /// The group that is playing, or paused if none is, with what it is playing. Stopped groups
    /// keep a track loaded for days, which isn't "now playing". Home-theatre and Spotify Connect
    /// inputs are skipped: they carry no track metadata here (and Connect sessions are what the
    /// Spotify API already shows). Which group the notch then shows is `show(_:)`'s business.
    func snapshot() async -> (group: SonosGroup, snapshot: MediaSnapshot)? {
        await refreshTopologyIfStale()
        let groups = groups
        guard !groups.isEmpty else { return nil }
        let readings: [(SonosGroup, MediaSnapshot)] = await withTaskGroup(of: (SonosGroup, MediaSnapshot?).self) { tasks in
            for group in groups {
                tasks.addTask { [self] in (group, await read(group)) }
            }
            var out: [(SonosGroup, MediaSnapshot)] = []
            for await (group, snapshot) in tasks {
                if let snapshot { out.append((group, snapshot)) }
            }
            return out
        }
        let order = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($1.id, $0) })
        let sorted = readings.sorted { order[$0.0.id, default: 0] < order[$1.0.id, default: 0] }
        let lastUsed = lastUsedGroup?.id
        guard let chosen = sorted.first(where: { $0.1.isPlaying }) ?? sorted.first(where: { $0.0.id == lastUsed }) ?? sorted.first
        else { return nil }
        return (chosen.0, chosen.1)
    }

    /// Makes `group` the one the notch shows: its rooms in the speakers panel, its queue, its
    /// transport. Nil when what's showing isn't on Sonos at all.
    func show(_ group: SonosGroup?) async {
        guard let group else {
            activeGroup = nil
            return
        }
        // Keep the latest topology's version if it has one: grouping edits land there first, and
        // a hand-over there has already moved the group to its new coordinator.
        activeGroup = current(group)
        if wantsVolumes { await refreshVolumes() }
        if wantsQueue { await refreshQueue() }
    }

    /// The group a Spotify Connect device name stands for. Sonos registers a group with Spotify
    /// under its coordinator's room name, sometimes with the "+ 1" the app shows appended.
    func group(forDevice name: String) -> SonosGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let bare = trimmed.replacingOccurrences(of: #"\s*\+\s*\d+$"#, with: "", options: .regularExpression)
        let candidates = [trimmed, bare]
        func same(_ a: String, _ b: String) -> Bool { a.localizedCaseInsensitiveCompare(b) == .orderedSame }
        if let byLabel = groups.first(where: { group in candidates.contains { same($0, group.label) || same($0, group.name) } }) {
            return byLabel
        }
        return groups.first { group in group.members.contains { room in candidates.contains { same($0, room.name) } } }
    }

    private func read(_ group: SonosGroup) async -> MediaSnapshot? {
        do {
            let ip = group.coordinatorIP
            async let transport = soap(ip: ip, service: "AVTransport", path: "/MediaRenderer/AVTransport/Control", action: "GetTransportInfo", body: "<InstanceID>0</InstanceID>")
            async let position = soap(ip: ip, service: "AVTransport", path: "/MediaRenderer/AVTransport/Control", action: "GetPositionInfo", body: "<InstanceID>0</InstanceID>")
            let state = Self.text("CurrentTransportState", in: try await transport) ?? ""
            let isPlaying: Bool
            switch state {
            case "PLAYING", "TRANSITIONING": isPlaying = true
            case "PAUSED_PLAYBACK": isPlaying = false
            // The shown group stopping (its queue ran out, a stream dropped) still shows, paused,
            // so play goes back to it rather than to whatever player happens to be next.
            case "STOPPED" where group.id == activeGroup?.id: isPlaying = false
            // Likewise the speakers last used here, until something else is shown: a launch
            // with nothing playing starts on them.
            case "STOPPED" where activeGroup == nil && group.id == lastUsedGroup?.id: isPlaying = false
            default: return nil
            }
            let positionXML = try await position
            let uri = Self.text("TrackURI", in: positionXML) ?? ""
            if uri.hasPrefix("x-sonos-htastream:") || uri.hasPrefix("x-sonos-vli:") || uri.hasPrefix("x-rincon:") {
                return nil
            }
            guard let metadata = Self.text("TrackMetaData", in: positionXML).map(Self.unescape),
                  let title = Self.text("dc:title", in: metadata).map(Self.unescape), !title.isEmpty
            else { return nil }
            // Radio streams put the live track in streamContent and the station in the title.
            let stream = Self.text("r:streamContent", in: metadata).map(Self.unescape) ?? ""
            let creator = Self.text("dc:creator", in: metadata).map(Self.unescape) ?? ""
            var art = Self.text("upnp:albumArtURI", in: metadata).map(Self.unescape) ?? ""
            if art.hasPrefix("/") { art = "http://\(ip):1400\(art)" }
            let snapshot = MediaSnapshot(
                title: stream.isEmpty ? title : stream,
                artist: stream.isEmpty ? creator : title,
                isPlaying: isPlaying,
                artworkURL: art,
                position: Self.seconds(Self.text("RelTime", in: positionXML)),
                duration: Self.seconds(Self.text("TrackDuration", in: positionXML)) ?? 0,
                label: "Sonos · \(group.label)"
            )
            if group.id == activeGroup?.id {
                lastActiveReading = (group.id, snapshot)
                activeReadFailures = 0
            }
            return snapshot
        } catch {
            sonosLog.error("\(group.label, privacy: .public) unreachable: \(error.localizedDescription, privacy: .public)")
            // A speaker busy regrouping misses a poll or two. The shown group keeps its last
            // reading through that, or the notch would hand the controls to another player.
            if group.id == activeGroup?.id, let last = lastActiveReading, last.groupID == group.id,
               activeReadFailures < Self.readFailuresTolerated {
                activeReadFailures += 1
                return last.snapshot
            }
            return nil
        }
    }

    // MARK: Grouping

    /// Ticks or unticks `room` in `group`, the way the Sonos app's room picker does: ticked, the
    /// room plays what the group plays; unticked, it is on its own again. Unticking the room
    /// that is streaming hands the stream to another member first, so the music carries on in
    /// the rest of the group. The last room can't be unticked. The topology is edited locally
    /// at once so the list answers the click; the speakers' own version replaces it a moment
    /// later. Returns the group's coordinator afterwards, which changes on a hand-over.
    ///
    /// Edits run one at a time, each against the group as the one before left it: a speaker
    /// mid-regroup stops answering, and overlapping clicks timed out and broke the group up.
    @discardableResult
    func setGrouped(_ room: SonosRoom, _ grouped: Bool, in group: SonosGroup) async -> String? {
        regroupPending = false
        let previous = groupingTail
        let edit = Task { @MainActor [weak self] () -> String? in
            await previous?.value
            guard let self else { return nil }
            return await self.regroup(room, grouped, in: self.current(group, besides: room))
        }
        groupingTail = Task { _ = await edit.value }
        let coordinator = await edit.value
        if let coordinator, let edited = groups.first(where: { $0.id == coordinator }) { remember(edited) }
        return coordinator
    }

    /// `group` as the topology has it now. A hand-over changes its id, so failing that, the
    /// group holding any of its rooms other than `room`.
    private func current(_ group: SonosGroup, besides room: SonosRoom? = nil) -> SonosGroup {
        if let same = groups.first(where: { $0.id == group.id }) { return same }
        let others = Set(group.members.map(\.uuid)).subtracting([room?.uuid].compactMap { $0 })
        return groups.first { $0.members.contains { others.contains($0.uuid) } } ?? group
    }

    private func regroup(_ room: SonosRoom, _ grouped: Bool, in group: SonosGroup) async -> String? {
        let isMember = group.members.contains { $0.uuid == room.uuid }
        guard grouped != isMember else { return group.id }
        let others = group.members.filter { $0.uuid != room.uuid }
        if !grouped, others.isEmpty { return group.id }
        let isCoordinator = room.uuid == group.coordinatorUUID
        let successor = isCoordinator && !grouped ? others.first : nil
        let newCoordinator = successor?.uuid ?? group.coordinatorUUID

        applyLocally(room: room, grouped: grouped, in: group, coordinator: newCoordinator)
        do {
            if grouped {
                _ = try await soap(
                    ip: room.ip, service: "AVTransport", path: "/MediaRenderer/AVTransport/Control",
                    action: "SetAVTransportURI",
                    body: "<InstanceID>0</InstanceID><CurrentURI>x-rincon:\(group.coordinatorUUID)</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
                )
            } else if let successor {
                // An AVTransport action, despite the name: the stream moves with the coordination.
                _ = try await soap(
                    ip: room.ip, service: "AVTransport", path: "/MediaRenderer/AVTransport/Control",
                    action: "DelegateGroupCoordinationTo",
                    body: "<InstanceID>0</InstanceID><NewCoordinator>\(successor.uuid)</NewCoordinator><RejoinGroup>0</RejoinGroup>"
                )
            } else {
                _ = try await soap(
                    ip: room.ip, service: "AVTransport", path: "/MediaRenderer/AVTransport/Control",
                    action: "BecomeCoordinatorOfStandaloneGroup", body: "<InstanceID>0</InstanceID>"
                )
            }
            sonosLog.notice("\(room.name, privacy: .public) \(grouped ? "joined" : "left", privacy: .public) \(group.name, privacy: .public)\(successor.map { ", handed to \($0.name)" } ?? "", privacy: .public)")
        } catch {
            sonosLog.error("grouping \(room.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        // Sonos takes a beat to publish the new topology.
        try? await Task.sleep(for: .milliseconds(600))
        if let knownSpeaker { await refreshTopology(from: knownSpeaker) }
        return newCoordinator
    }

    /// Adds `room` to the playing group or splits it back off. Fire-and-forget form of the above.
    func setGrouped(_ room: SonosRoom, _ grouped: Bool) {
        guard let activeGroup else { return }
        Task { await setGrouped(room, grouped, in: activeGroup) }
    }

    /// The topology as it will read once the speakers have applied a grouping edit.
    private func applyLocally(room: SonosRoom, grouped: Bool, in group: SonosGroup, coordinator: String) {
        var updated = groups
        // Lift the room out of wherever it is. A group it was coordinating carries on under
        // its first remaining member, which is what the speakers do too.
        for index in updated.indices {
            guard updated[index].members.contains(where: { $0.uuid == room.uuid }) else { continue }
            updated[index].members.removeAll { $0.uuid == room.uuid }
            if updated[index].coordinatorUUID == room.uuid, let next = updated[index].members.first {
                updated[index].coordinatorUUID = next.uuid
                updated[index].coordinatorIP = next.ip
                updated[index].name = next.name
            }
        }
        updated.removeAll { $0.members.isEmpty }
        if grouped {
            if let index = updated.firstIndex(where: { $0.id == group.id }) {
                updated[index].members.append(room)
                updated[index].members.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        } else {
            updated.append(SonosGroup(coordinatorUUID: room.uuid, coordinatorIP: room.ip, name: room.name, members: [room]))
        }
        updated.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        groups = updated
        if activeGroup?.id == group.id, let shown = updated.first(where: { $0.id == coordinator }) {
            activeGroup = shown
        }
    }

    // MARK: Volume

    private static let renderingPath = "/MediaRenderer/RenderingControl/Control"
    private static let groupRenderingPath = "/MediaRenderer/GroupRenderingControl/Control"
    private static let groupVolumeKey = "group"

    /// Reads volume and mute for every room in the shown group, and the group volume when there
    /// is more than one. Rooms with a change still settling are skipped.
    func refreshVolumes() async {
        guard let activeGroup else { return }
        let members = activeMembers
        let now = Date()
        await withTaskGroup(of: (String, Int?, Bool?).self) { tasks in
            for room in members {
                tasks.addTask { [self] in
                    async let volumeXML = soap(ip: room.ip, service: "RenderingControl", path: Self.renderingPath, action: "GetVolume", body: "<InstanceID>0</InstanceID><Channel>Master</Channel>")
                    async let muteXML = soap(ip: room.ip, service: "RenderingControl", path: Self.renderingPath, action: "GetMute", body: "<InstanceID>0</InstanceID><Channel>Master</Channel>")
                    let volume = (try? await volumeXML).flatMap { Self.text("CurrentVolume", in: $0) }.flatMap { Int($0) }
                    let mute = (try? await muteXML).flatMap { Self.text("CurrentMute", in: $0) }.map { $0 == "1" }
                    return (room.uuid, volume, mute)
                }
            }
            for await (uuid, volume, mute) in tasks {
                if let hold = volumeHoldUntil[uuid], hold > now { continue }
                if let volume { volumes[uuid] = volume }
                if let mute {
                    if mute { muted.insert(uuid) } else { muted.remove(uuid) }
                }
            }
        }
        guard members.count > 1 else {
            groupVolume = nil
            return
        }
        if let hold = volumeHoldUntil[Self.groupVolumeKey], hold > now { return }
        let xml = try? await soap(ip: activeGroup.coordinatorIP, service: "GroupRenderingControl", path: Self.groupRenderingPath, action: "GetGroupVolume", body: "<InstanceID>0</InstanceID>")
        groupVolume = xml.flatMap { Self.text("CurrentVolume", in: $0) }.flatMap { Int($0) }
    }

    func setVolume(_ room: SonosRoom, _ level: Int) {
        let level = min(max(level, 0), 100)
        volumes[room.uuid] = level
        volumeHoldUntil[room.uuid] = Date().addingTimeInterval(1.5)
        sendLatest(key: room.uuid) { [self] in
            _ = try await soap(
                ip: room.ip, service: "RenderingControl", path: Self.renderingPath, action: "SetVolume",
                body: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(level)</DesiredVolume>"
            )
        }
    }

    func setMuted(_ room: SonosRoom, _ isMuted: Bool) {
        if isMuted { muted.insert(room.uuid) } else { muted.remove(room.uuid) }
        volumeHoldUntil[room.uuid] = Date().addingTimeInterval(1.5)
        sendLatest(key: "mute:" + room.uuid) { [self] in
            _ = try await soap(
                ip: room.ip, service: "RenderingControl", path: Self.renderingPath, action: "SetMute",
                body: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredMute>\(isMuted ? 1 : 0)</DesiredMute>"
            )
        }
    }

    /// Scales every room in the group together, the way the Sonos app's group slider does. The
    /// per-room levels that result come back on the next poll.
    func setGroupVolume(_ level: Int) {
        guard let activeGroup else { return }
        let level = min(max(level, 0), 100)
        groupVolume = level
        volumeHoldUntil[Self.groupVolumeKey] = Date().addingTimeInterval(1.5)
        sendLatest(key: Self.groupVolumeKey) { [self] in
            _ = try await soap(
                ip: activeGroup.coordinatorIP, service: "GroupRenderingControl", path: Self.groupRenderingPath,
                action: "SetGroupVolume", body: "<InstanceID>0</InstanceID><DesiredVolume>\(level)</DesiredVolume>"
            )
        }
    }

    /// A slider fires many times a second. Each key gets one request in flight at a time, with
    /// only the newest value waiting behind it, so a drag ends on the level it was released at
    /// without queueing every step along the way.
    private func sendLatest(key: String, _ request: @escaping @MainActor () async throws -> Void) {
        queued[key] = request
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task {
            while let next = queued.removeValue(forKey: key) {
                do {
                    try await next()
                } catch {
                    sonosLog.error("volume \(key, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            inFlight.remove(key)
        }
    }

    // MARK: Controls

    func play() async throws {
        if let activeGroup { _ = await regroupLastUsed(into: activeGroup) }
        try await transport("Play", body: "<InstanceID>0</InstanceID><Speed>1</Speed>")
        if let activeGroup { remember(current(activeGroup)) }
    }
    func pause() async throws { try await transport("Pause", body: "<InstanceID>0</InstanceID>") }
    func next() async throws { try await transport("Next", body: "<InstanceID>0</InstanceID>") }
    func previous() async throws { try await transport("Previous", body: "<InstanceID>0</InstanceID>") }

    func seek(to seconds: Double) async throws {
        let target = Self.clock(seconds)
        try await transport("Seek", body: "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>\(target)</Target>")
    }

    /// Plays the queue from its `index`th item (1-based).
    func jump(to index: Int) {
        Task {
            do {
                try await transport("Seek", body: "<InstanceID>0</InstanceID><Unit>TRACK_NR</Unit><Target>\(index)</Target>")
                try await play()
                queueIndex = index
            } catch {
                sonosLog.error("jump to \(index) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func transport(_ action: String, body: String) async throws {
        guard let activeGroup else { throw SonosError.message("No Sonos group is active.") }
        _ = try await soap(ip: activeGroup.coordinatorIP, service: "AVTransport", path: "/MediaRenderer/AVTransport/Control", action: action, body: body)
    }

    // MARK: SOAP

    func soap(ip: String, service: String, path: String, action: String, body: String = "") async throws -> String {
        var request = URLRequest(url: URL(string: "http://\(ip):1400\(path)")!)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:\(service):1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
        <u:\(action) xmlns:u="urn:schemas-upnp-org:service:\(service):1">\(body)</u:\(action)>\
        </s:Body></s:Envelope>
        """.utf8)
        let isRead = action.hasPrefix("Get") || action == "Browse" || action == "ListAvailableServices"
        let (data, response) = try await (isRead ? session : writeSession).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let xml = String(decoding: data, as: UTF8.self)
        guard status == 200 else {
            let code = Self.text("errorCode", in: xml) ?? "\(status)"
            throw SonosError.message("Sonos \(action) failed (UPnP error \(code)).")
        }
        return xml
    }

    // MARK: SSDP

    /// Multicast M-SEARCH for ZonePlayers; answers arrive as unicast on the same socket. Blocking,
    /// so it runs detached. Returns speaker IPs, deduplicated, in the order they answered.
    private nonisolated static func ssdpDiscover() -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var ttl: Int32 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))

        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(1900).bigEndian
        dest.sin_addr.s_addr = inet_addr("239.255.255.250")
        let message = Array("""
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 1\r
        ST: urn:schemas-upnp-org:device:ZonePlayer:1\r
        \r

        """.utf8)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &dest) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(fd, message, message.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var found: [String] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    recvfrom(fd, &buffer, buffer.count, 0, address, &fromLength)
                }
            }
            guard count > 0 else { continue }
            let reply = String(decoding: buffer[0..<count], as: UTF8.self)
            // Other UPnP devices answer any search; only ZonePlayers describe themselves on 1400.
            guard reply.range(of: ":1400/xml/device_description.xml") != nil else { continue }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            if !found.contains(ip) { found.append(ip) }
        }
        return found
    }

    // MARK: Parsing

    private nonisolated static func parseGroups(_ state: String) -> [SonosGroup] {
        guard let groupRegex = try? NSRegularExpression(pattern: #"<ZoneGroup Coordinator="([^"]+)"[^>]*>(.*?)</ZoneGroup>"#, options: [.dotMatchesLineSeparators]),
              let memberRegex = try? NSRegularExpression(pattern: #"<ZoneGroupMember ([^>]*?)/?>"#),
              let attributeRegex = try? NSRegularExpression(pattern: #"(\w+)="([^"]*)""#)
        else { return [] }
        let whole = NSRange(state.startIndex..., in: state)
        var groups: [SonosGroup] = []
        for match in groupRegex.matches(in: state, range: whole) {
            guard let coordinatorRange = Range(match.range(at: 1), in: state),
                  let bodyRange = Range(match.range(at: 2), in: state) else { continue }
            let coordinator = String(state[coordinatorRange])
            let body = String(state[bodyRange])
            var coordinatorIP: String?
            var name = ""
            var members: [SonosRoom] = []
            for member in memberRegex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let attributesRange = Range(member.range(at: 1), in: body) else { continue }
                let attributesText = String(body[attributesRange])
                var attributes: [String: String] = [:]
                for attribute in attributeRegex.matches(in: attributesText, range: NSRange(attributesText.startIndex..., in: attributesText)) {
                    guard let keyRange = Range(attribute.range(at: 1), in: attributesText),
                          let valueRange = Range(attribute.range(at: 2), in: attributesText) else { continue }
                    attributes[String(attributesText[keyRange])] = String(attributesText[valueRange])
                }
                // Invisible members are the second half of a stereo pair or a surround satellite.
                if attributes["Invisible"] == "1" { continue }
                let roomName = unescape(attributes["ZoneName"] ?? "")
                guard let uuid = attributes["UUID"],
                      let ip = attributes["Location"].flatMap({ URL(string: $0)?.host }),
                      !roomName.isEmpty
                else { continue }
                members.append(SonosRoom(uuid: uuid, ip: ip, name: roomName))
                if uuid == coordinator {
                    name = roomName
                    coordinatorIP = ip
                }
            }
            guard let coordinatorIP, !name.isEmpty else { continue }
            members.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            groups.append(SonosGroup(coordinatorUUID: coordinator, coordinatorIP: coordinatorIP, name: name, members: members))
        }
        return groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Text between `<tag>` and `</tag>`; the tags this needs never carry attributes.
    nonisolated static func text(_ tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    nonisolated static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    nonisolated static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// "0:03:11" → 191. Sonos reports NOT_IMPLEMENTED for inputs it can't time.
    private nonisolated static func seconds(_ clock: String?) -> Double? {
        guard let clock else { return nil }
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    private nonisolated static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

enum SonosError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
