import SwiftUI

/// Artwork with a name under it. Hovering shows the play badge; starting shows a spinner there.
struct LibraryTile: View {
    var title: String
    var subtitle: String
    var artworkURL: String
    var size: CGFloat
    var starting: Bool
    var disabled: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                artwork
                    .overlay(alignment: .bottomTrailing) {
                        if starting {
                            ProgressView()
                                .controlSize(.mini)
                                .padding(5)
                        } else if hovering {
                            Image(systemName: "play.fill")
                                .font(.ui(8, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.white))
                                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                                .padding(4)
                        }
                    }
                Text(title)
                    .font(.ui(size >= 72 ? 10 : 9, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.ui(8))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(width: size, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help("Play \(title)")
    }

    private var artwork: some View {
        ZStack {
            Color.white.opacity(0.1)
            Image(systemName: "music.note")
                .font(.ui(size / 4))
                .foregroundStyle(.white.opacity(0.4))
            if let url = URL(string: artworkURL), !artworkURL.isEmpty {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
