import SwiftUI

struct StorageSettingsView: View {
    @EnvironmentObject var jellyfinService: JellyfinService
    @ObservedObject private var downloadManager = DownloadManager.shared
    @AppStorage("prefetchNextSong") private var prefetchNextSong: Bool = true
    @State private var showClearCacheAlert = false
    @State private var showClearDownloadsAlert = false
    @State private var showClearAlbumArtAlert = false
    @State private var cacheSize: Double = 0
    @State private var downloadsSize: Double = 0
    @State private var albumArtSize: Double = 0
    @State private var recentlyPlayedCount: Int = 0

    var body: some View {
        List {
            Section {
                Picker("settings.storage.quality", selection: $jellyfinService.audioQuality) {
                    ForEach(AudioQuality.allCases, id: \.self) { quality in
                        Text(quality.description).tag(quality)
                    }
                }

                Text("settings.storage.quality_footer")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("settings.storage.audio_quality.header")
            }

            Section("settings.storage.downloads.header") {
                HStack {
                    Text("settings.storage.downloads_size")
                    Spacer()
                    Text(String(format: "%.1f MB", downloadsSize))
                        .foregroundColor(.secondary)
                }

                Button(action: { showClearDownloadsAlert = true }) {
                    Text("settings.storage.clear_downloads")
                        .foregroundColor(.red)
                }
            }

            Section {
                Toggle("settings.storage.prefetch", isOn: $prefetchNextSong)

                Text("settings.storage.prefetch_footer")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("settings.storage.cache_size")
                    Spacer()
                    Text(String(format: "%.1f MB", cacheSize))
                        .foregroundColor(.secondary)
                }

                Button(action: { showClearCacheAlert = true }) {
                    Text("settings.storage.clear_cache")
                        .foregroundColor(.red)
                }
            } header: {
                Text("settings.storage.cache.header")
            }

            Section("settings.storage.album_art.header") {
                HStack {
                    Text("settings.storage.album_art_size")
                    Spacer()
                    Text(String(format: "%.1f MB", albumArtSize))
                        .foregroundColor(.secondary)
                }

                Button(action: { showClearAlbumArtAlert = true }) {
                    Text("settings.storage.clear_album_art")
                        .foregroundColor(.red)
                }
            }

            Section("settings.storage.recently_played.header") {
                HStack {
                    Text("settings.storage.recently_played.albums")
                    Spacer()
                    Text(verbatim: "\(recentlyPlayedCount)")
                        .foregroundColor(.secondary)
                }

                Button(action: {
                    AudioPlayerManager.shared.clearRecentlyPlayed()
                    recentlyPlayedCount = 0
                }) {
                    Text("settings.storage.clear_recently_played")
                        .foregroundColor(.red)
                }
                .disabled(recentlyPlayedCount == 0)
            }
        }
        .navigationTitle("settings.storage.title")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            updateSizes()
            recentlyPlayedCount = AudioPlayerManager.shared.recentlyPlayedAlbumIds.count
        }
        .alert("settings.storage.clear_downloads", isPresented: $showClearDownloadsAlert) {
            Button("common.cancel", role: .cancel) {}
            Button("common.clear", role: .destructive) {
                downloadManager.clearAllDownloads()
                updateSizes()
            }
        } message: {
            Text("settings.storage.clear_downloads.message")
        }
        .alert("settings.storage.clear_cache", isPresented: $showClearCacheAlert) {
            Button("common.cancel", role: .cancel) {}
            Button("common.clear", role: .destructive) {
                downloadManager.clearCache()
                updateSizes()
            }
        } message: {
            Text("settings.storage.clear_cache.message")
        }
        .alert("settings.storage.clear_album_art", isPresented: $showClearAlbumArtAlert) {
            Button("common.cancel", role: .cancel) {}
            Button("common.clear", role: .destructive) {
                downloadManager.clearAlbumArtCache()
                ImageCacheManager.shared.clearCache()
                updateSizes()
            }
        } message: {
            Text("settings.storage.clear_album_art.message")
        }
    }

    private func updateSizes() {
        Task {
            let sizes = await Task.detached(priority: .userInitiated) {
                return (
                    DownloadManager.shared.getCacheSizeInMB(),
                    DownloadManager.shared.getDownloadsSizeInMB(),
                    DownloadManager.shared.getAlbumArtSizeInMB()
                )
            }.value
            cacheSize = sizes.0
            downloadsSize = sizes.1
            albumArtSize = sizes.2
        }
    }
}
