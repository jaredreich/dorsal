import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerManager
    @State private var showNowPlaying = false

    var body: some View {
        LibraryView()
            .safeAreaInset(edge: .bottom) {
                if audioPlayer.currentSong != nil {
                    MiniPlayerView(showNowPlaying: $showNowPlaying)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: audioPlayer.currentSong != nil)
            .sheet(isPresented: $showNowPlaying) {
                NowPlayingView(showNowPlaying: $showNowPlaying)
                    .environmentObject(audioPlayer)
                    .presentationDragIndicator(.hidden)
                    .presentationDetents([.large])
                    .interactiveDismissDisabled(false)
            }
    }
}
