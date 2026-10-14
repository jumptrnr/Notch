import SwiftUI

/// A small capsule with an icon and a word or two: the output name under the track, the group
/// picker in the browser, the active state of either. `filled` inverts it to white on black.
struct Chip: View {
    var icon: String
    var text: String
    var detail: String? = nil
    var chevron: String? = nil
    var filled = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.ui(9, weight: .semibold))
            Text(text)
                .font(.ui(10, weight: .semibold))
                .lineLimit(1)
            if let detail {
                Text("· \(detail)")
                    .font(.ui(10, weight: .medium))
                    .opacity(0.5)
                    .lineLimit(1)
            }
            if let chevron {
                Image(systemName: chevron)
                    .font(.ui(7, weight: .bold))
                    .opacity(0.6)
            }
        }
        .foregroundStyle(filled ? Color.black : Color.white)
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .frame(height: 18)
        .background(Capsule().fill(filled ? Color.white : Color.white.opacity(0.14)))
        .contentShape(Capsule())
    }
}

/// Every room in the house as one list, the way the Sonos app's room picker has it: the rooms
/// in `group` first, ticked, then the rest. Ticking a room pulls it into the group; unticking
/// splits it off, and unticking the room that is streaming hands the music to another member.
/// With `volume` each member row also carries its mute, slider and level. `select`, when given,
/// makes the name of a room outside the group a way to switch the whole picker to that room's
/// group instead of merging it in.
struct RoomList: View {
    @ObservedObject var sonos: SonosController
    var group: SonosGroup?
    var volume = false
    var select: ((SonosGroup) -> Void)? = nil
    /// Called with the group's coordinator after an edit, which changes when the streaming
    /// room leaves; whoever tracks the group by id follows it here.
    var regrouped: (String) -> Void = { _ in }

    /// Rooms with an edit in flight, so a second click can't race the first.
    @State private var busy: Set<String> = []

    private var members: [SonosRoom] {
        guard let group else { return [] }
        let current = sonos.groups.first { $0.id == group.id } ?? group
        return current.members.sorted { a, b in
            if a.uuid == current.coordinatorUUID { return true }
            if b.uuid == current.coordinatorUUID { return false }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private var others: [SonosRoom] {
        let members = members
        return sonos.rooms.filter { room in !members.contains { $0.uuid == room.uuid } }
    }

    var body: some View {
        let members = members
        let others = others
        VStack(spacing: 4) {
            ForEach(members) { room in
                row(room, member: true, coordinator: room.uuid == group?.coordinatorUUID, alone: members.count == 1)
            }
            if !members.isEmpty, !others.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
                    .padding(.vertical, 1)
            }
            ForEach(others) { room in
                row(room, member: false, coordinator: false, alone: false)
            }
        }
    }

    private func row(_ room: SonosRoom, member: Bool, coordinator: Bool, alone: Bool) -> some View {
        let isMuted = member && sonos.muted.contains(room.uuid)
        let isBusy = busy.contains(room.uuid)
        // The one room left can't be unticked: the music has to come out somewhere.
        let canToggle = group != nil && !isBusy && !(member && alone)
        let home = member ? nil : sonos.groups.first { $0.members.contains { $0.uuid == room.uuid } }
        return HStack(spacing: 8) {
            Button {
                toggle(room, member: member)
            } label: {
                ZStack {
                    if isBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: member ? "checkmark.circle.fill" : "circle")
                            .font(.ui(13, weight: .medium))
                            .foregroundStyle(.white.opacity(member ? 1 : 0.35))
                    }
                }
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canToggle)
            .help(member ? (alone ? "The only room playing" : "Stop playing here") : "Play here too")
            name(room, member: member, coordinator: coordinator, home: home)
                .frame(width: volume ? 98 : nil, alignment: .leading)
                .opacity(isMuted ? 0.6 : 1)
            if volume, member {
                Button {
                    sonos.setMuted(room, !isMuted)
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                        .font(.ui(10))
                        .foregroundStyle(.white.opacity(isMuted ? 0.45 : 0.8))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isMuted ? "Unmute" : "Mute")
                VolumeSlider(level: sonos.volumes[room.uuid], dimmed: isMuted) { sonos.setVolume(room, $0) }
                Text(sonos.volumes[room.uuid].map(String.init) ?? "–")
                    .font(.ui(10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, alignment: .trailing)
                    .opacity(isMuted ? 0.6 : 1)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(height: 22)
    }

    /// The room's name, with where it is when it's elsewhere. Outside the group, the name is
    /// itself a way to switch to that room when the picker allows it.
    @ViewBuilder
    private func name(_ room: SonosRoom, member: Bool, coordinator: Bool, home: SonosGroup?) -> some View {
        let label = HStack(spacing: 4) {
            Text(room.name)
                .font(.ui(10, weight: .semibold))
                .foregroundStyle(.white.opacity(member ? 1 : 0.6))
                .lineLimit(1)
            if coordinator {
                // The room doing the streaming; the others follow it.
                Image(systemName: "waveform")
                    .font(.ui(7, weight: .semibold))
                    .foregroundStyle(.green)
                    .help("This room is streaming")
            } else if let home, home.members.count > 1 {
                Text("with \(home.name)")
                    .font(.ui(8))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        if let select, let home, !member {
            Button {
                select(home)
            } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Switch to \(home.label)")
        } else {
            label
        }
    }

    private func toggle(_ room: SonosRoom, member: Bool) {
        guard let group else { return }
        busy.insert(room.uuid)
        Task {
            if let coordinator = await sonos.setGrouped(room, !member, in: group) {
                regrouped(coordinator)
            }
            busy.remove(room.uuid)
        }
    }
}

/// The compact form of the room picker, for where a list won't fit: the chosen group's name on a
/// chip, and a menu with every room to tick in or out plus the other groups to switch to.
struct OutputPicker: View {
    @ObservedObject var sonos: SonosController
    @Binding var selection: String?
    var current: SonosGroup?

    var body: some View {
        Menu {
            if let current {
                let live = sonos.groups.first { $0.id == current.id } ?? current
                Section("Rooms") {
                    ForEach(sonos.rooms) { room in
                        let member = live.members.contains { $0.uuid == room.uuid }
                        Button {
                            Task {
                                if let coordinator = await sonos.setGrouped(room, !member, in: live) {
                                    selection = coordinator
                                }
                            }
                        } label: {
                            if member {
                                Label(room.name, systemImage: "checkmark")
                            } else {
                                Text(room.name)
                            }
                        }
                        .disabled(member && live.members.count == 1)
                    }
                }
            }
            // Also offered with no group chosen, so a picker whose group went away isn't empty.
            let others = sonos.groups.filter { $0.id != current?.id }
            if !others.isEmpty {
                Section("Switch to") {
                    ForEach(others) { group in
                        Button(group.label) { selection = group.id }
                    }
                }
            }
        } label: {
            Chip(icon: "hifispeaker.fill", text: current?.label ?? "No speakers", chevron: "chevron.down")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Play on")
    }
}
