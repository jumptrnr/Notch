import SwiftUI

/// The shown Sonos group's queue in the lyrics panel's slot: every song, the one playing
/// marked and kept in view, any other a click away.
struct QueueView: View {
    @ObservedObject var sonos: SonosController

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("QUEUE · \(sonos.queue.count) \(sonos.queue.count == 1 ? "SONG" : "SONGS")")
                    .font(.ui(8, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if !sonos.queueIsSource {
                    Text("Playing a stream, not the queue")
                        .font(.ui(8))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(height: 14)
            if sonos.queue.isEmpty {
                Text(sonos.queueFetchedAt == nil ? "Reading the queue…" : "The queue is empty")
                    .font(.ui(10))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 1) {
                            ForEach(sonos.queue) { item in
                                row(item, current: item.index == sonos.queueIndex)
                                    .id(item.index)
                            }
                        }
                        .padding(.trailing, 2)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { reveal(proxy, animated: false) }
                    .onChange(of: sonos.queueIndex) { _, _ in reveal(proxy, animated: true) }
                    .onChange(of: sonos.queue.count) { _, _ in reveal(proxy, animated: false) }
                }
            }
        }
        .onAppear {
            sonos.wantsQueue = true
            Task { await sonos.refreshQueue(force: true) }
        }
        .onDisappear { sonos.wantsQueue = false }
    }

    private func reveal(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let index = sonos.queueIndex else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(index, anchor: .center) }
        } else {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    private func row(_ item: SonosQueueItem, current: Bool) -> some View {
        Button {
            sonos.jump(to: item.index)
        } label: {
            HStack(spacing: 8) {
                Group {
                    if current {
                        Image(systemName: "waveform")
                            .font(.ui(8, weight: .semibold))
                            .foregroundStyle(.green)
                    } else {
                        Text("\(item.index)")
                            .font(.ui(8, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .frame(width: 18, alignment: .trailing)
                ZStack {
                    Color.white.opacity(0.1)
                    if let url = URL(string: item.artworkURL), !item.artworkURL.isEmpty {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            }
                        }
                    }
                }
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                Text(item.title)
                    .font(.ui(10, weight: current ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(current ? 1 : 0.85))
                    .lineLimit(1)
                Text(item.artist)
                    .font(.ui(9))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(current ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(current ? "Playing" : "Play from here")
    }
}
