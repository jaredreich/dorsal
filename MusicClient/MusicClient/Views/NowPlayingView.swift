import SwiftUI
import AVKit

struct NowPlayingView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerManager
    @ObservedObject private var themeManager = ThemeManager.shared
    @Binding var showNowPlaying: Bool
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    private var duration: Double {
        let d = audioPlayer.duration
        guard d.isFinite, d > 0 else { return 1.0 }
        return d
    }

    private var safeCurrentTime: Double {
        let t = audioPlayer.currentTime
        guard t.isFinite else { return 0.0 }
        return max(0, min(t, duration))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { _ in
        NavigationView {
            ZStack {
                Color.clear
                    .background(.regularMaterial)
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    Spacer()

                    AlbumArtView(
                        imageUrl: audioPlayer.currentSong?.imageUrl,
                        albumId: audioPlayer.currentSong?.albumId ?? "",
                        size: (UIDevice.current.userInterfaceIdiom == .pad || UIScreen.main.bounds.height <= 667) ? 200 : 300
                    )
                    .cornerRadius(20)
                    .shadow(radius: 20)
                    .padding(.horizontal)

                    VStack(spacing: 4) {
                        Text(audioPlayer.currentSong?.name ?? "")
                            .font(.title)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(height: 34)

                        Text(audioPlayer.currentSong?.artistName ?? "")
                            .font(.title3)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(height: 24)
                    }
                    .padding(.horizontal, 40)

                    VStack(spacing: 0) {
                        ScrubberView(
                            progress: isScrubbing ? scrubTime / duration : safeCurrentTime / duration,
                            isScrubbing: $isScrubbing,
                            onScrub: { fraction in
                                let maxTime = max(duration - 5, 0)
                                scrubTime = min(fraction * duration, maxTime)
                            },
                            onScrubEnd: { fraction in
                                let maxTime = max(duration - 5, 0)
                                let seekTime = min(fraction * duration, maxTime)
                                audioPlayer.seek(to: seekTime)
                            }
                        )

                        HStack {
                            Text((isScrubbing ? scrubTime : safeCurrentTime).formattedDuration)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundColor(.secondary)

                            Spacer()

                            Text((audioPlayer.currentSong?.duration ?? duration).formattedDuration)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 40)

                    HStack(spacing: 40) {
                        Button(action: { audioPlayer.playPrevious() }) {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.primary)
                        }

                        Button(action: { audioPlayer.togglePlayPause() }) {
                            ZStack {
                                Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 64))
                                    .foregroundColor(.primary)
                                    .opacity(audioPlayer.isLoading ? 0 : 1)

                                if audioPlayer.isLoading {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .scaleEffect(2.0)
                                }
                            }
                        }
                        .disabled(audioPlayer.isLoading)

                        Button(action: { audioPlayer.playNext() }) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.primary)
                        }
                        .disabled(!audioPlayer.hasNext)
                        .opacity(audioPlayer.hasNext ? 1.0 : 0.3)
                    }

                    Spacer()
                }
                .padding(.vertical)
            }
            .navigationTitle("now_playing.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        audioPlayer.stop()
                        showNowPlaying = false
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundColor(.primary)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    AirPlayButton()
                        .frame(width: 30, height: 30)
                }
            }
        }
        }
    }
}

struct ScrubberView: View {
    let progress: Double
    @Binding var isScrubbing: Bool
    let onScrub: (Double) -> Void
    let onScrubEnd: (Double) -> Void

    private let trackHeight: CGFloat = 4
    private let expandedTrackHeight: CGFloat = 8
    private let hitTargetHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clampedProgress = min(max(progress, 0), 1)
            let fillWidth = clampedProgress * width
            let currentTrackHeight = isScrubbing ? expandedTrackHeight : trackHeight

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.2))
                    .frame(height: currentTrackHeight)

                Capsule()
                    .fill(Color.primary)
                    .frame(width: max(fillWidth, currentTrackHeight), height: currentTrackHeight)
            }
            .animation(.easeOut(duration: 0.15), value: isScrubbing)
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            isScrubbing = true
                        }
                        let fraction = min(max(value.location.x / width, 0), 1)
                        onScrub(fraction)
                    }
                    .onEnded { value in
                        let fraction = min(max(value.location.x / width, 0), 1)
                        onScrubEnd(fraction)
                        isScrubbing = false
                    }
            )
        }
        .frame(height: hitTargetHeight)
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()
        routePickerView.tintColor = UIColor.label
        routePickerView.activeTintColor = UIColor(Color.appAccent)
        routePickerView.prioritizesVideoDevices = false
        return routePickerView
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
