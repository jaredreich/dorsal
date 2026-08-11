import Foundation
import Combine
import Intents

@MainActor
protocol DownloadManaging: ObservableObject {
    var downloadProgress: [String: Double] { get set }
    var downloadingSongIds: Set<String> { get set }
    var downloadingAlbumIds: Set<String> { get set }
    var pinnedAlbums: Set<String> { get set }
    var recentlyPlayedAlbumIds: [String] { get set }
    var activeDownloadCount: Int { get set }
    var cachedContentVersion: Int { get set }
    func saveAlbumMetadata(albumId: String, album: Album, songs: [Song], updateIndex: Bool)
    func downloadAlbum(_ album: Album, songs: [Song])
    func getAlbumArtUrl(for albumId: String) -> URL
    func cancelDownload(songId: String)
    func albumDownloadProgress(albumId: String) -> Double
    func cancelAlbumDownload(albumId: String)
    func deleteAlbum(albumId: String)
    func isPinned(albumId: String) -> Bool
    func cleanupStaleAlbums(serverAlbumIds: Set<String>)
    func existingStorageUrl(for songId: String) -> URL?
    func isCached(songId: String) -> Bool
    func downloadAndCache(_ song: Song) async throws -> URL
    func getCacheSizeInMB() -> Double
    func clearCache()
    func deleteSongFromCache(songId: String)
    func getDownloadsSizeInMB() -> Double
    func clearAllDownloads()
    func getAlbumArtSizeInMB() -> Double
    func clearAlbumArtCache()
    func addToRecentlyPlayed(albumId: String)
    func clearRecentlyPlayed()
    func removeFromRecentlyPlayed(albumId: String)
    func reorderRecentlyPlayed(newOrder: [String])
    func loadSongsForAlbum(_ albumId: String, album: Album) async throws -> [Song]
    func donateVocabularyToSiri(albums: [Album])
}

@MainActor
class DownloadManager: NSObject, DownloadManaging {
    static let shared = DownloadManager()

    var downloadProgress: [String: Double] = [:]
    @Published var downloadingSongIds: Set<String> = []
    @Published var downloadingAlbumIds: Set<String> = []
    @Published var pinnedAlbums: Set<String> = []
    @Published var recentlyPlayedAlbumIds: [String] = []
    @Published var activeDownloadCount: Int = 0
    @Published var cachedContentVersion: Int = 0

    // Song IDs that finished downloading in the current session
    private var completedSongs: Set<String> = []
    // Song IDs with files on disk
    private var cachedSongIds: Set<String> = []
    // Tracks which song IDs remain for each active album download
    private var pendingAlbumDownloads: [String: Set<String>] = [:]
    // Maps song ID to URLSessionDownloadTask (for cancelling individual in-flight song downloads)
    private var activeDownloads: [String: URLSessionDownloadTask] = [:]
    // Maps song ID to CheckedContinuation (bridges callback-based URLSession to async/await)
    private var downloadContinuations: [String: CheckedContinuation<URL, Error>] = [:]
    // Albums waiting to start downloading (queued but not yet active)
    private var albumDownloadQueue: [(Album, [Song])] = []
    // Whether an album is currently being processed from the queue
    private var isProcessingAlbumQueue = false

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.jaredreich.download")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let fileManager = FileManager.default
    private let appGroupId = "group.com.jaredreich.shared"

    private var storageDirectory: URL {
        // Try to use App Group container first
        if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let url = container.appendingPathComponent("Storage", isDirectory: true)
            createStorageDirectories(at: url)
            return url
        }

        // Fallback to Documents directory if App Group is not available
        let url = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Storage", isDirectory: true)
        createStorageDirectories(at: url)
        return url
    }

    private var albumsDirectory: URL {
        storageDirectory.appendingPathComponent("albums", isDirectory: true)
    }

    private var songsDirectory: URL {
        storageDirectory.appendingPathComponent("songs", isDirectory: true)
    }

    private func createStorageDirectories(at baseUrl: URL) {
        let directories = [
            baseUrl,
            baseUrl.appendingPathComponent("albums", isDirectory: true),
            baseUrl.appendingPathComponent("songs", isDirectory: true)
        ]

        for directory in directories {
            if !fileManager.fileExists(atPath: directory.path) {
                try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
    }

    private let jellyfinService: any JellyfinServicing
    private let searchManager: any SearchManaging

    init(jellyfinService: (any JellyfinServicing)? = nil,
         searchManager: (any SearchManaging)? = nil) {
        self.jellyfinService = jellyfinService ?? JellyfinService.shared
        self.searchManager = searchManager ?? SearchManager.shared
        super.init()
        loadPinnedItems()
        loadRecentlyPlayedAlbums()
        buildCachedSongIndex()
    }

    // Scans the songs directory on startup to build an in-memory set
    // of cached song IDs (this makes isCached() an O(1) set lookup instead
    // of a fileExists() call on every render)
    private func buildCachedSongIndex() {
        guard let fileUrls = try? fileManager.contentsOfDirectory(at: songsDirectory, includingPropertiesForKeys: nil) else { return }
        for url in fileUrls {
            let songId = url.deletingPathExtension().lastPathComponent
            cachedSongIds.insert(songId)
        }
    }

    private func isSongInPinnedAlbum(_ songId: String) -> Bool {
        let protectedAlbums = pinnedAlbums.union(downloadingAlbumIds)
        for albumId in protectedAlbums {
            if let metadata = loadAlbumMetadata(for: albumId),
               metadata.songs.contains(where: { $0.id == songId }) {
                return true
            }
        }
        return false
    }

    private func getAlbumMetadataUrl(for albumId: String) -> URL {
        return albumsDirectory.appendingPathComponent("\(albumId).json")
    }

    // Saves album metadata to {albumId}.json
    // If the album's imageTag has changed, deletes stale artwork so it gets re-fetched
    // Set updateIndex to false during batch operations, then call SearchManager.replaceAlbumsIndex() once after
    func saveAlbumMetadata(albumId: String, album: Album, songs: [Song], updateIndex: Bool = true) {
        // Check if album art has changed by comparing image tags
        if let newTag = album.imageTag,
           let existingMetadata = loadAlbumMetadata(for: albumId),
           let oldTag = existingMetadata.album.imageTag,
           newTag != oldTag {
            // Image tag changed, delete stale artwork so it gets re-fetched
            let artworkUrl = getAlbumArtUrl(for: albumId)
            try? fileManager.removeItem(at: artworkUrl)
        }

        let metadata = AlbumMetadata(album: album, songs: songs)
        let url = getAlbumMetadataUrl(for: albumId)

        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: url)
        } catch {
            print("Failed to save album metadata for \(albumId): \(error)")
        }

        // Update the in-memory albums index (skip during batch sync)
        if updateIndex {
            searchManager.updateAlbumInIndex(album)
        }
    }

    private func loadAlbumMetadata(for albumId: String) -> AlbumMetadata? {
        let url = getAlbumMetadataUrl(for: albumId)

        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let metadata = try JSONDecoder().decode(AlbumMetadata.self, from: data)
            return metadata
        } catch {
            return nil
        }
    }

    // Unified download method (downloads a song using URLSessionDownloadTask with progress tracking)
    // Supports both async/await (for playback) and fire-and-forget (for batch downloads)
    @discardableResult
    private func downloadSong(_ song: Song, awaitCompletion: Bool = false) async throws -> URL {
        // Generate asset URL dynamically with current quality settings
        guard let assetUrlString = jellyfinService.getAssetUrl(for: song),
              let assetUrl = URL(string: assetUrlString) else {
            throw NSError(domain: "DownloadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not generate assetUrl"])
        }

        // Check if already cached (regardless of extension/quality)
        if let existingUrl = existingStorageUrl(for: song.id) {
            return existingUrl
        }

        // Initialize progress immediately so that UI updates right away
        await MainActor.run {
            downloadProgress[song.id] = 0.0
            downloadingSongIds.insert(song.id)
        }

        // If we need to await completion, use continuation
        if awaitCompletion {
            return try await withCheckedThrowingContinuation { continuation in
                downloadContinuations[song.id] = continuation

                let downloadTask = urlSession.downloadTask(with: assetUrl)
                downloadTask.taskDescription = song.id
                activeDownloads[song.id] = downloadTask
                downloadTask.resume()
            }
        } else {
            // Fire-and-forget for batch downloads
            let downloadTask = urlSession.downloadTask(with: assetUrl)
            downloadTask.taskDescription = song.id
            activeDownloads[song.id] = downloadTask
            downloadTask.resume()
            // Just return a placeholder, actual path is determined when download completes
            return songsDirectory.appendingPathComponent(song.id)
        }
    }

    func downloadAlbum(_ album: Album, songs: [Song]) {
        saveAlbumMetadata(albumId: album.id, album: album, songs: songs)
        downloadAlbumArt(for: album)

        let uncachedSongIds = Set(songs.filter { !isCached(songId: $0.id) }.map { $0.id })

        if uncachedSongIds.isEmpty {
            // All songs are already cached, can pin immediately, no need to queue
            pinnedAlbums.insert(album.id)
            savePinnedItems()
            return
        }

        pendingAlbumDownloads[album.id] = uncachedSongIds
        downloadingAlbumIds.insert(album.id)

        // Queue the album and process sequentially
        albumDownloadQueue.append((album, songs))
        processNextAlbumDownload()
    }

    private func processNextAlbumDownload() {
        guard !isProcessingAlbumQueue, !albumDownloadQueue.isEmpty else { return }
        isProcessingAlbumQueue = true

        let (album, songs) = albumDownloadQueue.removeFirst()

        // Set this album's uncached songs as downloading
        downloadingSongIds.formUnion(pendingAlbumDownloads[album.id] ?? [])
        activeDownloadCount = activeDownloads.count

        Task {
            for song in songs {
                guard self.downloadingAlbumIds.contains(album.id) else { break }
                _ = try? await downloadSong(song, awaitCompletion: true)
            }

            await MainActor.run {
                self.isProcessingAlbumQueue = false
                self.processNextAlbumDownload()
            }
        }
    }

    private func downloadAlbumArt(for album: Album) {
        let destinationUrl = getAlbumArtUrl(for: album.id)
        guard !FileManager.default.fileExists(atPath: destinationUrl.path),
              let imageUrlString = album.imageUrl,
              let imageUrl = URL(string: imageUrlString) else {
            return
        }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: imageUrl)
                try data.write(to: destinationUrl)
            } catch {
                print("Failed to download album art for \(album.id): \(error)")
            }
        }
    }

    func getAlbumArtUrl(for albumId: String) -> URL {
        return albumsDirectory.appendingPathComponent("\(albumId).jpg")
    }

    func cancelDownload(songId: String) {
        activeDownloads[songId]?.cancel()
        activeDownloads.removeValue(forKey: songId)
        downloadProgress.removeValue(forKey: songId)
        downloadingSongIds.remove(songId)

        if let continuation = downloadContinuations.removeValue(forKey: songId) {
            continuation.resume(throwing: CancellationError())
        }
    }

    func albumDownloadProgress(albumId: String) -> Double {
        guard let metadata = loadAlbumMetadata(for: albumId) else { return 0 }
        let total = metadata.songs.count
        guard total > 0 else { return 0 }
        let cached = metadata.songs.filter { cachedSongIds.contains($0.id) }.count
        return Double(cached) / Double(total)
    }

    func cancelAlbumDownload(albumId: String) {
        // Remove from queue if not yet started
        albumDownloadQueue.removeAll { $0.0.id == albumId }

        guard let pendingSongIds = pendingAlbumDownloads[albumId] else { return }
        for songId in pendingSongIds where !cachedSongIds.contains(songId) {
            cancelDownload(songId: songId)
        }
        pendingAlbumDownloads.removeValue(forKey: albumId)
        downloadingAlbumIds.remove(albumId)
        activeDownloadCount = activeDownloads.count
    }

    func deleteAlbum(albumId: String) {
        pinnedAlbums.remove(albumId)
        savePinnedItems()

        // Cancel any in-progress download
        pendingAlbumDownloads.removeValue(forKey: albumId)
        downloadingAlbumIds.remove(albumId)
    }

    func isPinned(albumId: String) -> Bool {
        return pinnedAlbums.contains(albumId)
    }

    // Removes everything that is not on the server
    func cleanupStaleAlbums(serverAlbumIds: Set<String>) {
        guard !serverAlbumIds.isEmpty,
              let metadataFiles = try? fileManager.contentsOfDirectory(at: albumsDirectory, includingPropertiesForKeys: nil) else { return }

        let diskAlbumIds = Set(
            metadataFiles
                .filter { $0.pathExtension == "json" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )

        let staleAlbumIds = diskAlbumIds.subtracting(serverAlbumIds)
        guard !staleAlbumIds.isEmpty else { return }

        for albumId in staleAlbumIds {
            // Load song IDs before deleting metadata
            let songIds = loadAlbumMetadata(for: albumId)?.songs.map { $0.id } ?? []

            // Delete cached songs
            for songId in songIds {
                if let url = existingStorageUrl(for: songId) {
                    try? fileManager.removeItem(at: url)
                }
                cachedSongIds.remove(songId)
            }

            // Delete metadata and artwork
            let metadataUrl = getAlbumMetadataUrl(for: albumId)
            let artworkUrl = getAlbumArtUrl(for: albumId)
            try? fileManager.removeItem(at: metadataUrl)
            try? fileManager.removeItem(at: artworkUrl)

            // Clean up download state
            cancelAlbumDownload(albumId: albumId)
            pinnedAlbums.remove(albumId)

        }

        // Clean up recently played
        for albumId in staleAlbumIds {
            removeFromRecentlyPlayed(albumId: albumId)
        }

        savePinnedItems()
        cachedContentVersion += 1
    }

    // Checks if all songs for any pending album download are now cached
    // If yes, pins the album and removes it from the pending list
    private func checkPendingAlbumDownloads() {
        // Snapshot keys to avoid mutating dictionary while iterating
        let albumIds = Array(pendingAlbumDownloads.keys)
        var didPin = false

        for albumId in albumIds {
            guard let songIds = pendingAlbumDownloads[albumId] else { continue }
            if songIds.allSatisfy({ cachedSongIds.contains($0) }) {
                pinnedAlbums.insert(albumId)
                pendingAlbumDownloads.removeValue(forKey: albumId)
                downloadingAlbumIds.remove(albumId)
                didPin = true
            }
        }

        if didPin {
            savePinnedItems()
        }
    }

    func existingStorageUrl(for songId: String) -> URL? {
        if let files = try? fileManager.contentsOfDirectory(at: songsDirectory, includingPropertiesForKeys: nil),
           let existing = files.first(where: { $0.deletingPathExtension().lastPathComponent == songId }) {
            return existing
        }
        return nil
    }

    nonisolated private static func resolveSongsDirectory(_ fm: FileManager) -> URL {
        let appGroupId = "group.com.jaredreich.shared"
        let base: URL
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            base = container.appendingPathComponent("Storage", isDirectory: true)
        } else {
            base = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Storage", isDirectory: true)
        }
        return base.appendingPathComponent("songs", isDirectory: true)
    }

    nonisolated private static func extensionForMimeType(_ mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "audio/mp4", "audio/aac", "audio/x-m4a", "audio/mp4a-latm": return "m4a"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/ogg", "audio/vorbis": return "ogg"
        case "audio/opus": return "opus"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/x-aiff", "audio/aiff": return "aiff"
        case "audio/webm": return "webm"
        default: return "m4a"
        }
    }

    func isCached(songId: String) -> Bool {
        return cachedSongIds.contains(songId)
    }

    func downloadAndCache(_ song: Song) async throws -> URL {
        var metadata: AlbumMetadata
        if let existing = loadAlbumMetadata(for: song.albumId) {
            // Album metadata exists, add song if not already present
            var songs = existing.songs
            if !songs.contains(where: { $0.id == song.id }) {
                songs.append(song)
            }
            metadata = AlbumMetadata(album: existing.album, songs: songs)
        } else {
            // Create new album metadata for this song
            let album = Album(
                id: song.albumId,
                name: song.albumName,
                artistName: song.artistName,
                year: nil,
                imageUrl: song.imageUrl,
                songCount: nil,
                dateAdded: nil
            )
            metadata = AlbumMetadata(album: album, songs: [song])
        }

        saveAlbumMetadata(albumId: song.albumId, album: metadata.album, songs: metadata.songs)

        await cacheAlbumArtIfNeeded(albumId: song.albumId, imageUrl: song.imageUrl)

        return try await downloadSong(song, awaitCompletion: true)
    }

    private func cacheAlbumArtIfNeeded(albumId: String, imageUrl: String?) async {
        guard let imageUrlString = imageUrl,
              let imageUrl = URL(string: imageUrlString) else {
            return
        }

        let albumArtUrl = getAlbumArtUrl(for: albumId)

        // Check if album art already exists
        if fileManager.fileExists(atPath: albumArtUrl.path) {
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: imageUrl)
            try data.write(to: albumArtUrl)
        } catch {
            print("Failed to cache album art for \(albumId): \(error)")
        }
    }

    // Returns cache size for auto-cached (non-pinned) songs only
    func getCacheSizeInMB() -> Double {
        guard let fileUrls = try? fileManager.contentsOfDirectory(at: songsDirectory, includingPropertiesForKeys: [.fileSizeKey], options: []) else {
            return 0
        }

        // Build set of song IDs from pinned albums for efficient lookups
        var pinnedSongIds = Set<String>()
        for albumId in pinnedAlbums {
            if let metadata = loadAlbumMetadata(for: albumId) {
                pinnedSongIds.formUnion(metadata.songs.map { $0.id })
            }
        }

        // Calculate size of unpinned song files only
        let unpinnedBytes = fileUrls.reduce(0) { total, url in
            let filename = url.lastPathComponent
            let songId = filename.components(separatedBy: ".").first ?? ""

            // Skip if pinned song
            if pinnedSongIds.contains(songId) {
                return total
            }

            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + fileSize
        }

        return Double(unpinnedBytes) / 1_048_576.0
    }

    func clearCache() {
        do {
            let fileUrls = try fileManager.contentsOfDirectory(at: songsDirectory, includingPropertiesForKeys: nil)

            // Build set of song IDs from pinned albums for efficient lookups
            var pinnedSongIds = Set<String>()
            for albumId in pinnedAlbums {
                if let metadata = loadAlbumMetadata(for: albumId) {
                    pinnedSongIds.formUnion(metadata.songs.map { $0.id })
                }
            }

            var deletedCount = 0
            var deletedSongIds = Set<String>()

            for fileUrl in fileUrls {
                let filename = fileUrl.lastPathComponent
                let songId = filename.components(separatedBy: ".").first ?? ""

                // Skip if this is a pinned song
                if pinnedSongIds.contains(songId) {
                    continue
                }

                try fileManager.removeItem(at: fileUrl)
                deletedCount += 1
                deletedSongIds.insert(songId)
            }

            // Remove deleted songs from completedSongs and cachedSongIds
            completedSongs.subtract(deletedSongIds)
            cachedSongIds.subtract(deletedSongIds)

            // Notify observers that cached content changed
            if deletedCount > 0 {
                cachedContentVersion += 1
            }
        } catch {
            print("Failed to clear cache: \(error)")
        }
    }

    func deleteSongFromCache(songId: String) {
        // Don't delete if song belongs to a pinned album
        if isSongInPinnedAlbum(songId) {
            return
        }

        guard let storageUrl = existingStorageUrl(for: songId) else { return }

        do {
            try fileManager.removeItem(at: storageUrl)

            // Remove from completedSongs so it can be re-downloaded
            completedSongs.remove(songId)
            cachedSongIds.remove(songId)

            // Notify observers that cached content changed
            cachedContentVersion += 1
        } catch {
            print("Failed to delete song \(songId) from cache: \(error)")
        }
    }

    func getDownloadsSizeInMB() -> Double {
        var totalBytes = 0

        // Calculate pinned songs size
        if let songUrls = try? fileManager.contentsOfDirectory(at: songsDirectory, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            // Build set of song IDs from pinned albums for efficient lookups
            var pinnedSongIds = Set<String>()
            for albumId in pinnedAlbums {
                if let metadata = loadAlbumMetadata(for: albumId) {
                    pinnedSongIds.formUnion(metadata.songs.map { $0.id })
                }
            }

            // Calculate size of pinned song files
            let songBytes = songUrls.reduce(0) { total, url in
                let filename = url.lastPathComponent
                let songId = filename.components(separatedBy: ".").first ?? ""

                // Only include if this is a pinned song
                if pinnedSongIds.contains(songId) {
                    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return total + fileSize
                }

                return total
            }
            totalBytes += songBytes
        }

        // Add metadata size for pinned albums
        if let albumFileUrls = try? fileManager.contentsOfDirectory(at: albumsDirectory, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            let albumFileBytes = albumFileUrls.reduce(0) { total, url in
                let filename = url.lastPathComponent
                let albumId = filename.replacingOccurrences(of: ".json", with: "")

                if pinnedAlbums.contains(albumId) {
                    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return total + fileSize
                }

                return total
            }
            totalBytes += albumFileBytes
        }

        // Add artwork size for pinned albums
        if let artworkUrls = try? fileManager.contentsOfDirectory(at: albumsDirectory, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            let artworkBytes = artworkUrls.reduce(0) { total, url in
                let filename = url.lastPathComponent

                guard filename.hasSuffix(".jpg") else { return total }

                let albumId = filename.replacingOccurrences(of: ".jpg", with: "")

                if pinnedAlbums.contains(albumId) {
                    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return total + fileSize
                }

                return total
            }
            totalBytes += artworkBytes
        }

        return Double(totalBytes) / 1_048_576.0
    }

    func clearAllDownloads() {
        let albumIds = Array(pinnedAlbums)

        for albumId in albumIds {
            deleteAlbum(albumId: albumId)
        }
    }

    // Returns album art cache size for non-pinned albums only (in MB)
    // Pinned album artwork is counted in getDownloadsSizeInMB() instead
    func getAlbumArtSizeInMB() -> Double {
        guard let fileUrls = try? fileManager.contentsOfDirectory(at: albumsDirectory, includingPropertiesForKeys: [.fileSizeKey], options: []) else {
            return 0
        }

        let totalBytes = fileUrls.reduce(0) { total, url in
            let filename = url.lastPathComponent

            // Only count .jpg files (artwork), not .json files (metadata)
            guard filename.hasSuffix(".jpg") else { return total }

            let albumId = filename.replacingOccurrences(of: ".jpg", with: "")

            // Skip if this is a pinned album (counted in downloads instead)
            if pinnedAlbums.contains(albumId) {
                return total
            }

            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + fileSize
        }

        return Double(totalBytes) / 1_048_576.0
    }

    // Clears album art cache for non-pinned albums only
    // Pinned album artwork is preserved as part of downloaded content
    func clearAlbumArtCache() {
        do {
            let fileUrls = try fileManager.contentsOfDirectory(at: albumsDirectory, includingPropertiesForKeys: nil)

            for fileUrl in fileUrls {
                let filename = fileUrl.lastPathComponent

                // Only delete .jpg files (artwork), not .json files (metadata)
                guard filename.hasSuffix(".jpg") else { continue }

                let albumId = filename.replacingOccurrences(of: ".jpg", with: "")

                // Skip if this is a pinned album
                if pinnedAlbums.contains(albumId) {
                    continue
                }

                try fileManager.removeItem(at: fileUrl)
            }
        } catch {
            print("Failed to clear album art cache: \(error)")
        }
    }

    private func loadPinnedItems() {
        if let data = UserDefaults.standard.data(forKey: "pinnedAlbums"),
           let albums = try? JSONDecoder().decode(Set<String>.self, from: data) {
            pinnedAlbums = albums

            // Rebuild completedSongs from pinned albums
            for albumId in albums {
                if let metadata = loadAlbumMetadata(for: albumId) {
                    for song in metadata.songs {
                        completedSongs.insert(song.id)
                    }
                }
            }
        }
    }

    private func savePinnedItems() {
        if let data = try? JSONEncoder().encode(pinnedAlbums) {
            UserDefaults.standard.set(data, forKey: "pinnedAlbums")
        }
    }

    private func loadRecentlyPlayedAlbums() {
        if let data = UserDefaults.standard.data(forKey: "recentlyPlayedAlbumIds"),
           let albumIds = try? JSONDecoder().decode([String].self, from: data) {
            recentlyPlayedAlbumIds = albumIds
        }
    }

    private func saveRecentlyPlayedAlbums() {
        if let data = try? JSONEncoder().encode(recentlyPlayedAlbumIds) {
            UserDefaults.standard.set(data, forKey: "recentlyPlayedAlbumIds")
        }
    }

    func addToRecentlyPlayed(albumId: String) {
        recentlyPlayedAlbumIds.removeAll { $0 == albumId }
        recentlyPlayedAlbumIds.insert(albumId, at: 0)
        if recentlyPlayedAlbumIds.count > 100 {
            recentlyPlayedAlbumIds = Array(recentlyPlayedAlbumIds.prefix(100))
        }
        saveRecentlyPlayedAlbums()
    }

    func clearRecentlyPlayed() {
        recentlyPlayedAlbumIds = []
        saveRecentlyPlayedAlbums()
    }

    func removeFromRecentlyPlayed(albumId: String) {
        recentlyPlayedAlbumIds.removeAll { $0 == albumId }
        saveRecentlyPlayedAlbums()
    }

    func reorderRecentlyPlayed(newOrder: [String]) {
        recentlyPlayedAlbumIds = newOrder
        saveRecentlyPlayedAlbums()
    }

    // Loads songs for an album, checking pinned first, then fetching from server with metadata fallback
    // Songs are always returned sorted by disc and track number regardless of source
    func loadSongsForAlbum(_ albumId: String, album: Album) async throws -> [Song] {
        let songs: [Song]

        // Check if album is pinned and load from local storage
        if isPinned(albumId: albumId) {
            songs = searchManager.getSongsForAlbum(albumId)
        } else {
            // Try to fetch from server first to get complete song list
            do {
                songs = try await jellyfinService.fetchSongs(for: albumId)

                // Save metadata so all songs become searchable
                saveAlbumMetadata(albumId: albumId, album: album, songs: songs)
            } catch {
                // If server fetch fails, fall back to metadata (all songs, not just cached)
                let metadataSongs = searchManager.getSongsForAlbum(albumId)

                if !metadataSongs.isEmpty {
                    songs = metadataSongs
                } else {
                    // No metadata available at all
                    throw error
                    // TODO: handle this better
                }
            }
        }

        // Universal sorting, ensures consistent order regardless of source
        return songs.sortedByTrack()
    }

    // Donates all artist names to Siri for better voice recognition
    func donateVocabularyToSiri(albums: [Album]) {
        var artistNames: [String] = []

        for album in albums {
            if !album.artistName.isEmpty {
                artistNames.append(album.artistName)
            }
        }

        let uniqueArtists = NSOrderedSet(array: artistNames)

        INVocabulary.shared().setVocabularyStrings(uniqueArtists, of: .mediaMusicArtistName)

        print("Donated vocabulary to Siri: \(uniqueArtists.count) artists")
    }

}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let songId = downloadTask.taskDescription else { return }

        let fileExtension: String
        if let mimeType = downloadTask.response?.mimeType {
            fileExtension = Self.extensionForMimeType(mimeType)
        } else if let suggestedName = downloadTask.response?.suggestedFilename,
                  let ext = suggestedName.split(separator: ".").last {
            fileExtension = String(ext).lowercased()
        } else {
            fileExtension = "m4a"
        }

        let fm = FileManager.default
        let songsDir = Self.resolveSongsDirectory(fm)
        let destinationUrl = songsDir.appendingPathComponent("\(songId).\(fileExtension)")

        do {
            if fm.fileExists(atPath: destinationUrl.path) {
                try fm.removeItem(at: destinationUrl)
            }
            try fm.moveItem(at: location, to: destinationUrl)

            Task { @MainActor in
                self.completedSongs.insert(songId)
                self.cachedSongIds.insert(songId)
                self.activeDownloads.removeValue(forKey: songId)
                self.downloadProgress.removeValue(forKey: songId)
                self.downloadingSongIds.remove(songId)
                self.activeDownloadCount = self.activeDownloads.count

                if let continuation = self.downloadContinuations.removeValue(forKey: songId) {
                    continuation.resume(returning: destinationUrl)
                }

                self.checkPendingAlbumDownloads()
                self.cachedContentVersion += 1
            }
        } catch {
            Task { @MainActor in
                if let continuation = self.downloadContinuations.removeValue(forKey: songId) {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let songId = downloadTask.taskDescription else { return }

        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            self.downloadProgress[songId] = progress
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        guard let songId = task.taskDescription else { return }

        Task { @MainActor in
            self.activeDownloads.removeValue(forKey: songId)
            self.downloadProgress.removeValue(forKey: songId)
            self.downloadingSongIds.remove(songId)
            self.activeDownloadCount = self.activeDownloads.count

            if let continuation = self.downloadContinuations.removeValue(forKey: songId) {
                continuation.resume(throwing: error)
            }
        }
    }
}
