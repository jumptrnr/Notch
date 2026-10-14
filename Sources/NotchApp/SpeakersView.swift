import SwiftUI

/// The rooms playing along with the shown group, and how loud. Takes the lyrics panel's slot
/// under the progress bar. Group volume first, then every room in the house as the Sonos app's
/// room picker lists them: the group's rooms ticked, with mute, slider and level; the rest
/// below, a tick away from joining in.
struct SpeakersView: View {
    @ObservedObject var sonos: SonosController

    var body: some View {
        let members = sonos.activeMembers
        ScrollView(.vertical) {
            VStack(spacing: 4) {
                if members.count > 1 {
                    groupRow(count: members.count)
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 1)
                        .padding(.vertical, 1)
                }
                RoomList(sonos: sonos, group: sonos.activeGroup, volume: true)
            }
            .padding(.trailing, 2)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Volume is only polled while this panel is out; see `SonosController.wantsVolumes`.
        .onAppear {
            sonos.wantsVolumes = true
            Task { await sonos.refreshVolumes() }
        }
        .onDisappear { sonos.wantsVolumes = false }
    }

    private func groupRow(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.ui(11))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text("GROUP · \(count) ROOMS")
                    .font(.ui(8, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.white.opacity(0.5))
                VolumeSlider(level: sonos.groupVolume, dimmed: false) { sonos.setGroupVolume($0) }
            }
            Text(sonos.groupVolume.map(String.init) ?? "–")
                .font(.ui(11, weight: .semibold).monospacedDigit())
                .frame(width: 22, alignment: .trailing)
        }
        .frame(height: 30)
    }
}

/// A thin track with a round knob, drawn here because the system slider draws its own chrome
/// on black. Drag anywhere on it; every move is sent and the controller coalesces them. Dead,
/// at zero, until the first reading arrives.
struct VolumeSlider: View {
    var level: Int?
    var dimmed: Bool
    var set: (Int) -> Void

    @State private var dragFraction: Double?

    private var fraction: Double {
        dragFraction ?? Double(level ?? 0) / 100
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let x = fraction * width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.white.opacity(dimmed ? 0.35 : 0.85))
                    .frame(width: x, height: 4)
                Circle()
                    .fill(dimmed ? Color(white: 0.56) : Color.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    .offset(x: min(max(x - 5, 0), width - 10))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let f = min(max(value.location.x / width, 0), 1)
                        dragFraction = f
                        set(Int((f * 100).rounded()))
                    }
                    .onEnded { _ in dragFraction = nil }
            )
        }
        .frame(height: 16)
        .disabled(level == nil)
        .opacity(level == nil ? 0.4 : 1)
    }
}
