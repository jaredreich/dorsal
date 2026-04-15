import SwiftUI
import Network

struct AlbumDetailView: View {
    @EnvironmentObject var jellyfinService: JellyfinService
    @EnvironmentObject var audioPlayer: AudioPlayerManager
    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var themeManager = ThemeManager.shared
    let album: Album

    @State private var songs: [Song] = []
    @State private var showDownloadAlert = false
    @State private var showClearCacheAlert = false
    @State private var isOffline = false
    @State private var networkMonitor: NWPathMonitor?

    private var isDownloading: Bool {
        downloadManager.downloadingAlbumIds.contains(album.id)
    }

    private var hasCachedSongs: Bool {
        songs.contains { song in
            downloadManager.isCached(songId: song.id)
        }
    }

    private var downloadProgress: Double {
        guard !songs.isEmpty else { return 0 }
        let cached = songs.filter { downloadManager.isCached(songId: $0.id) }.count
        return Double(cached) / Double(songs.count)
    }

    private var cachedSizeMB: Double {
        let totalBytes = songs.reduce(0) { total, song in
            guard downloadManager.isCached(songId: song.id),
                  let url = DownloadManager.shared.existingStorageUrl(for: song.id) else { return total }
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + fileSize
        }
        return Double(totalBytes) / 1_048_576.0
    }

    private var hasMultipleDiscs: Bool {
        album.hasMultipleDiscs(songs: songs)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    AlbumArtView(
                        imageUrl: album.imageUrl,
                        albumId: album.id,
                        size: 250
                    )
                    .shadow(radius: 10)

                    VStack(spacing: 0) {
                        Text(album.name)
                            .font(.title)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)

                        Text(album.artistName)
                            .font(.title3)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                }
                .padding()

                Button(action: playAlbum) {
                    Label("album.play", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundColor(.appAccent)
                        .frame(maxWidth: 300)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .background(Color.appAccent.opacity(0.3))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                }
                .disabled(songs.isEmpty || (isOffline && !songs.contains { isSongPlayable($0) }))
                .padding(.vertical, -8)

                if songs.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        Text("album.empty.title")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("album.empty.subtitle")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            VStack(spacing: 0) {
                                if hasMultipleDiscs && (index == 0 || songs[index - 1].discNumber != song.discNumber) {
                                    Text(verbatim: "\(String(localized: "general.disc")) \(song.discNumber ?? 1)")
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal)
                                        .padding(.vertical, 12)
                                        .background(Color(.systemGroupedBackground))
                                }

                                Button(action: { playSong(at: index) }) {
                                    SongRowView(
                                        song: song,
                                        isCurrentlyPlaying: audioPlayer.currentSong?.id == song.id,
                                        isCached: downloadManager.isCached(songId: song.id),
                                        isDownloading: downloadManager.downloadingSongIds.contains(song.id)
                                    )
                                    .opacity(isSongPlayable(song) ? 1.0 : 0.4)
                                }
                                .buttonStyle(.plain)
                                .disabled(!isSongPlayable(song))
                                .contextMenu {
                                    SongInfoContextMenu(song: song)
                                }

                                if index < songs.count - 1 {
                                    let nextSong = songs[index + 1]
                                    let isNextSongNewDisc = hasMultipleDiscs && nextSong.discNumber != song.discNumber

                                    if !isNextSongNewDisc {
                                        Divider()
                                            .padding(.leading, 60)
                                    }
                                }
                            }
                        }
                    }
                    .background(Color(.systemBackground))

                    VStack(alignment: .center, spacing: 4) {
                        if let year = album.year {
                            Text(String(year))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Text(verbatim: "\(songs.count) \(String(localized: "general.tracks")) · \(songs.totalMinutes) \(String(localized: "album.minutes"))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if cachedSizeMB > 0 {
                            Text(verbatim: "\(String(format: "%.1f MB", cachedSizeMB)) \(String(localized: "album.cached"))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom)
                }

                if audioPlayer.currentSong != nil {
                    Spacer(minLength: LayoutConstants.miniPlayerBottomPadding)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !downloadManager.isPinned(albumId: album.id) && hasCachedSongs && !isDownloading {
                    Menu {
                        Button {
                            showDownloadAlert = true
                        } label: {
                            Label("album.download", systemImage: "arrow.down.circle")
                        }

                        Button {
                            showClearCacheAlert = true
                        } label: {
                            Label("album.clear_cache", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .disabled(songs.isEmpty)
                } else if isDownloading {
                    Button {
                        downloadManager.cancelAlbumDownload(albumId: album.id)
                    } label: {
                        CircularDownloadProgress(progress: downloadProgress)
                    }
                } else {
                    Button {
                        showDownloadAlert = true
                    } label: {
                        if downloadManager.isPinned(albumId: album.id) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.appAccent)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                    .disabled(songs.isEmpty)
                }
            }
        }
        .onAppear {
            loadSongs()
        }
        .onDisappear {
            networkMonitor?.cancel()
            networkMonitor = nil
        }
        .onChange(of: isOffline) { _ in
            updatePlaybackQueueForConnectivity()
        }
        .alert(downloadManager.isPinned(albumId: album.id) ? LocalizedStringKey("album.undownload_alert.title") : LocalizedStringKey("album.download_alert.title"), isPresented: $showDownloadAlert) {
            Button("common.cancel", role: .cancel) {}
            if downloadManager.isPinned(albumId: album.id) {
                Button("common.clear", role: .destructive) {
                    deleteAlbum()
                }
            } else {
                Button("album.download") {
                    downloadAlbum()
                }
            }
        } message: {
            if downloadManager.isPinned(albumId: album.id) {
                Text("album.undownload_alert.message")
            } else {
                Text("album.download_alert.message")
            }
        }
        .alert("album.clear_cache_alert.title", isPresented: $showClearCacheAlert) {
            Button("common.cancel", role: .cancel) {}
            Button("common.clear", role: .destructive) {
                clearCache()
            }
        } message: {
            Text("album.clear_cache_alert.message")
        }
    }

    private func loadSongs() {
        let metadataSongs = SearchManager.shared.getSongsForAlbum(album.id).sortedByTrack()
        if !metadataSongs.isEmpty {
            songs = metadataSongs
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                isOffline = path.status != .satisfied
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        networkMonitor = monitor
    }

    private func isSongPlayable(_ song: Song) -> Bool {
        !isOffline || downloadManager.isCached(songId: song.id)
    }

    private func playAlbum() {
        guard !songs.isEmpty else { return }
        if isOffline {
            let playableSongs = songs.filter { isSongPlayable($0) }
            guard !playableSongs.isEmpty else { return }
            audioPlayer.play(queue: playableSongs, startIndex: 0)
        } else {
            audioPlayer.play(queue: songs, startIndex: 0)
        }
    }

    private func playSong(at index: Int) {
        if isOffline {
            let playableSongs = songs.filter { isSongPlayable($0) }
            guard let playableIndex = playableSongs.firstIndex(where: { $0.id == songs[index].id }) else { return }
            audioPlayer.play(queue: playableSongs, startIndex: playableIndex)
        } else {
            audioPlayer.play(queue: songs, startIndex: index)
        }
    }

    private func updatePlaybackQueueForConnectivity() {
        guard let currentSong = audioPlayer.currentSong,
              currentSong.albumId == album.id else { return }

        if isOffline {
            let playableSongs = songs.filter { isSongPlayable($0) }
            audioPlayer.updateQueue(playableSongs)
        } else {
            audioPlayer.updateQueue(songs)
        }
    }

    private func downloadAlbum() {
        downloadManager.downloadAlbum(album, songs: songs)
    }

    private func deleteAlbum() {
        downloadManager.deleteAlbum(albumId: album.id)
    }

    private func clearCache() {
        for song in songs {
            downloadManager.deleteSongFromCache(songId: song.id)
        }
    }
}

struct SongRowView: View {
    let song: Song
    let isCurrentlyPlaying: Bool
    let isCached: Bool
    let isDownloading: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(song.trackNumber ?? 0)")
                .font(.subheadline)
                .foregroundColor(isCurrentlyPlaying ? .appAccent : .secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(song.name)
                    .font(.body)
                    .foregroundColor(isCurrentlyPlaying ? .appAccent : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            Spacer()

            if isDownloading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            } else if isCached {
                Image(systemName: "circle.fill")
                    .foregroundColor(.gray)
                    .font(.system(size: 6))
            }

            if let duration = song.duration {
                Text(duration.formattedDuration)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding()
    }
}

struct SongInfoContextMenu: View {
    let song: Song

    private var fileInfo: (format: String, size: String, bitrate: String)? {
        guard let url = DownloadManager.shared.existingStorageUrl(for: song.id),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int64 else {
            return nil
        }

        let format = url.pathExtension.uppercased()
        let sizeMB = Double(fileSize) / 1_048_576.0
        let size = String(format: "%.1f MB", sizeMB)

        let bitrate: String
        if let duration = song.duration, duration > 0 {
            let kbps = Int(Double(fileSize) * 8.0 / duration / 1000.0)
            bitrate = "\(kbps) kbps"
        } else {
            bitrate = "Unknown"
        }

        return (format, size, bitrate)
    }

    var body: some View {
        Text(verbatim: song.name)
        Text(verbatim: song.albumName)
        Text(verbatim: song.artistName)
        if let disc = song.discNumber {
            Text(verbatim: "\(String(localized: "general.disc")): \(disc)")
        }
        if let track = song.trackNumber {
            Text(verbatim: "\(String(localized: "general.track")): \(track)")
        }
        if let duration = song.duration {
            Text(verbatim: "\(String(localized: "general.duration")): \(duration.formattedDuration)")
        }
        if let info = fileInfo {
            Text(verbatim: "\(String(localized: "general.cached")): ✓")
            Text(verbatim: "\(String(localized: "general.format")): \(info.format)")
            Text(verbatim: "\(String(localized: "general.bitrate")): \(info.bitrate)")
            Text(verbatim: "\(String(localized: "general.size")): \(info.size)")
        } else {
            Text(verbatim: "\(String(localized: "general.cached")): ✗")
        }
    }
}

private struct CircularDownloadProgress: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.appAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: progress)
        }
        .frame(width: 20, height: 20)
    }
}
