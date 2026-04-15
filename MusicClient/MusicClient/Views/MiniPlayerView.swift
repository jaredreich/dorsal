import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerManager
    @Binding var showNowPlaying: Bool
    @State private var dragLocation: CGPoint = .zero
    @State private var isPressed = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 12) {
                AlbumArtView(
                    imageUrl: audioPlayer.currentSong?.imageUrl,
                    albumId: audioPlayer.currentSong?.albumId ?? "",
                    size: 40
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.leading, 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(audioPlayer.currentSong?.name ?? "")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)

                    Text(audioPlayer.currentSong?.artistName ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: {
                    audioPlayer.togglePlayPause()
                }) {
                    ZStack {
                        Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundColor(.primary)
                            .frame(width: 44, height: 44)
                            .opacity(audioPlayer.isLoading ? 0 : 1)

                        if audioPlayer.isLoading {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(audioPlayer.isLoading)

                Button(action: {
                    audioPlayer.playNext()
                }) {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!audioPlayer.hasNext)
                .opacity(audioPlayer.hasNext ? 1.0 : 0.3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    Capsule()
                        .fill(.ultraThinMaterial)

                    if isPressed {
                        Capsule()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color.white.opacity(0.15),
                                        Color.white.opacity(0.05),
                                        Color.clear
                                    ],
                                    center: UnitPoint(
                                        x: dragLocation.x / geometry.size.width,
                                        y: dragLocation.y / geometry.size.height
                                    ),
                                    startRadius: 0,
                                    endRadius: 100
                                )
                            )
                            .blendMode(.overlay)
                    }

                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
            )
            .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
            .padding(.horizontal, 20)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragLocation = value.location
                        isPressed = true
                    }
                    .onEnded { _ in
                        isPressed = false
                        showNowPlaying = true
                    }
            )
        }
        .frame(height: 60)
        .padding(.top, 10)
        // NOTE: device-specific logic
        .padding(.bottom, UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.bottom == 0 ? 20 : 0)
    }
}
