import SwiftUI

/// The rooms on the Sonos network: which ones play along with the shown group, and how loud.
/// Takes the lyrics panel's slot under the progress bar. Rooms in the group get a mute button,
/// a slider and the level; the others only the checkbox that would pull them in.
struct SpeakersView: View {
    @ObservedObject var sonos: SonosController

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 2) {
                if sonos.activeMembers.count > 1 {
                    groupRow
                    Divider().overlay(Color.white.opacity(0.15))
                }
                ForEach(sonos.rooms) { room in
                    row(room)
                }
            }
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Volume is only polled while this panel is out; see `SonosController.wantsVolumes`.
        .onAppear {
            sonos.wantsVolumes = true
            Task { await sonos.refreshVolumes() }
        }
        .onDisappear { sonos.wantsVolumes = false }
    }

    private var groupRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 16)
            Text("Group")
                .font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 8)
            volumeSlider(level: sonos.groupVolume) { sonos.setGroupVolume($0) }
        }
        .frame(height: 26)
    }

    private func row(_ room: SonosRoom) -> some View {
        let inGroup = sonos.activeMembers.contains { $0.uuid == room.uuid }
        let isCoordinator = room.uuid == sonos.activeGroup?.coordinatorUUID
        let isMuted = sonos.muted.contains(room.uuid)
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { inGroup },
                set: { sonos.setGrouped(room, $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(isCoordinator)
            .help(isCoordinator ? "This room is streaming" : (inGroup ? "Leave the group" : "Join the group"))
            Text(room.name)
                .font(.system(size: 11, weight: inGroup ? .semibold : .regular))
                .foregroundStyle(.white.opacity(inGroup ? 1 : 0.55))
                .lineLimit(1)
            Spacer(minLength: 8)
            if inGroup {
                Button {
                    sonos.setMuted(room, !isMuted)
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(isMuted ? 0.45 : 0.8))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isMuted ? "Unmute" : "Mute")
                volumeSlider(level: sonos.volumes[room.uuid]) { sonos.setVolume(room, $0) }
            }
        }
        .frame(height: 26)
    }

    /// Disabled, at zero, until the first reading arrives.
    private func volumeSlider(level: Int?, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            Slider(
                value: Binding(get: { Double(level ?? 0) }, set: { set(Int($0.rounded())) }),
                in: 0...100
            )
            .controlSize(.mini)
            .tint(.white)
            .frame(width: 130)
            .disabled(level == nil)
            Text(level.map(String.init) ?? "–")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 22, alignment: .trailing)
        }
    }
}
