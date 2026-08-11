import Foundation
import Combine

enum SongsIndexState: Equatable {
    case notIndexed
    case indexing(Double)
    case indexed
}

// Mediator that manages album state between JellyfinService and DownloadManager
@MainActor
class AlbumStateManager: ObservableObject {
    static let shared = AlbumStateManager()

    @Published private(set) var albums: [Album] = []
    @Published var isSyncing: Bool = false
    @Published var albumSyncProgress: Double = 0
    @Published var songsIndexState: SongsIndexState = .notIndexed
    @Published var lastSyncDate: Date? = nil
    @Published var lastIndexedDate: Date? = nil

    // Albums available offline (pinned or with at least one cached song).
    // Pre-computed and cached, not re-evaluated during playback to avoid disk I/O on every render.
    @Published private(set) var offlineAlbums: [Album] = []

    // Album IDs that have at least one cached (non-pinned) song.
    // Used by AlbumRowView to show the grey dot without disk I/O.
    @Published private(set) var albumsWithCachedSongs: Set<String> = []

    private let jellyfinService: JellyfinService
    private let downloadManager: DownloadManager
    private let searchManager: any SearchManaging
    private var cancellables = Set<AnyCancellable>()

    init(jellyfinService: JellyfinService? = nil,
         downloadManager: DownloadManager? = nil,
         searchManager: (any SearchManaging)? = nil) {
        self.jellyfinService = jellyfinService ?? JellyfinService.shared
        self.downloadManager = downloadManager ?? DownloadManager.shared
        self.searchManager = searchManager ?? SearchManager.shared
        // Load persisted state
        let isIndexed = UserDefaults.standard.bool(forKey: "isSongsIndexed")
        songsIndexState = isIndexed ? .indexed : .notIndexed
        lastIndexedDate = UserDefaults.standard.object(forKey: "lastIndexedDate") as? Date
        lastSyncDate = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date

        // Observe changes to source albums from JellyfinService
        self.jellyfinService.$albums
            .sink { [weak self] serverAlbums in
                self?.updateAlbums(serverAlbums: serverAlbums)
            }
            .store(in: &cancellables)

        // Observe changes to pinned state (don't replace albums, just update offline set)
        self.downloadManager.$pinnedAlbums
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateOfflineAlbums()
            }
            .store(in: &cancellables)

        // Recompute offline albums when cached content changes (downloads complete or cache cleared)
        self.downloadManager.$cachedContentVersion
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateOfflineAlbums()
            }
            .store(in: &cancellables)

        loadCachedAlbums()
    }

    private func updateAlbums(serverAlbums: [Album]) {
        self.albums = serverAlbums
        updateOfflineAlbums()
    }

    private func updateOfflineAlbums() {
        var offline: [Album] = []
        var withCached: Set<String> = []

        for album in albums {
            if downloadManager.pinnedAlbums.contains(album.id) {
                offline.append(album)
                continue
            }
            let songs = searchManager.getSongsForAlbum(album.id)
            if songs.contains(where: { downloadManager.isCached(songId: $0.id) }) {
                offline.append(album)
                withCached.insert(album.id)
            }
        }

        offlineAlbums = offline
        albumsWithCachedSongs = withCached
    }

    // Loads cached albums for offline support (loads all album metadata from disk)
    func loadCachedAlbums() {
        let savedAlbums = searchManager.getAllAlbumsFromMetadata()

        // Create dictionary for fast lookup
        var albumDict: [String: Album] = [:]

        // First add saved albums from metadata
        for album in savedAlbums {
            albumDict[album.id] = album
        }

        // Then add/override with server albums if available (server takes precedence)
        for album in jellyfinService.albums {
            albumDict[album.id] = album
        }

        // Update albums array
        albums = Array(albumDict.values)
        updateOfflineAlbums()
    }

    // Returns filtered albums based on the filter option
    func getFilteredAlbums(filter: String) -> [Album] {
        let filtered: [Album]
        switch filter {
        case "Library":
            filtered = albums
        case "Latest Added":
            filtered = albums
        case "Recently Played":
            // Preserve recency order, map album IDs to albums in order
            let albumsById = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
            filtered = downloadManager.recentlyPlayedAlbumIds.compactMap { albumsById[$0] }
        case "Offline":
            filtered = offlineAlbums
        default:
            filtered = albums
        }

        // Apply sorting based on filter type
        switch filter {
        case "Recently Played":
            // Preserve recency order
            return filtered
        case "Latest Added":
            // Sort by dateAdded descending (most recent first)
            return filtered.sorted { album1, album2 in
                guard let date1 = album1.dateAdded, let date2 = album2.dateAdded else {
                    // Albums without dates go to the end
                    if album1.dateAdded == nil && album2.dateAdded == nil {
                        return false
                    }
                    return album1.dateAdded != nil
                }
                return date1 > date2
            }
        default:
            // Standard sort by artist and year
            return filtered.sorted(by: Album.standardSort)
        }
    }

    func quickSync() async throws {
        guard let lastSync = lastSyncDate else {
            try await sync()
            return
        }

        isSyncing = true
        albumSyncProgress = 0

        do {
            let changedAlbums = try await jellyfinService.fetchAlbumsSince(lastSync) { [weak self] progress in
                self?.albumSyncProgress = progress * 0.5
            }

            let changedSongMap = try await jellyfinService.fetchSongIdsSince(lastSync)
            let albumIdsFromSongs = Set(changedSongMap.values)

            let changedAlbumIds = Set(changedAlbums.map { $0.id })
            let additionalAlbumIds = albumIdsFromSongs.subtracting(changedAlbumIds)

            var allChangedAlbums = changedAlbums
            for albumId in additionalAlbumIds {
                if let album = try? await jellyfinService.fetchAlbum(id: albumId) {
                    allChangedAlbums.append(album)
                }
            }

            // Quick sync only adds/updates albums - it does NOT delete albums
            // because fetchAlbumsSince only returns changed items, not the full server list
            // Deletion of removed albums only happens during full sync
            mergeAlbums(allChangedAlbums)
            searchManager.replaceAlbumsIndex(albums)

            for (i, album) in allChangedAlbums.enumerated() {
                let songs = try await jellyfinService.fetchSongs(for: album.id)
                downloadManager.saveAlbumMetadata(albumId: album.id, album: album, songs: songs, updateIndex: false)
                albumSyncProgress = 0.5 + 0.5 * Double(i + 1) / Double(allChangedAlbums.count)
            }

            let affectedAlbumIds = Set(allChangedAlbums.map { $0.id })
            searchManager.updateSongsIndex(forAlbumIds: affectedAlbumIds)

            let now = Date()
            lastSyncDate = now
            UserDefaults.standard.set(now, forKey: "lastSyncDate")
            lastIndexedDate = now
            UserDefaults.standard.set(now, forKey: "lastIndexedDate")
            UserDefaults.standard.set(true, forKey: "isSongsIndexed")
            songsIndexState = .indexed

            isSyncing = false
            albumSyncProgress = 0
        } catch {
            isSyncing = false
            albumSyncProgress = 0
            throw error
        }
    }

    private func mergeAlbums(_ changedAlbums: [Album]) {
        var albumDict = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        for album in changedAlbums {
            albumDict[album.id] = album
        }
        albums = Array(albumDict.values)
        updateOfflineAlbums()
    }

    func sync() async throws {
        isSyncing = true
        songsIndexState = .notIndexed
        UserDefaults.standard.set(false, forKey: "isSongsIndexed")
        albumSyncProgress = 0

        do {
            try await jellyfinService.fetchAlbums { [weak self] progress in
                self?.albumSyncProgress = progress
            }

            searchManager.replaceAlbumsIndex(jellyfinService.albums)

            let serverAlbumIds = Set(jellyfinService.albums.map { $0.id })
            downloadManager.cleanupStaleAlbums(serverAlbumIds: serverAlbumIds)

            let now = Date()
            lastSyncDate = now
            UserDefaults.standard.set(now, forKey: "lastSyncDate")
            isSyncing = false
            albumSyncProgress = 0

            Task {
                await fetchAndIndexAllSongs()
            }
        } catch {
            isSyncing = false
            albumSyncProgress = 0
            throw error
        }
    }

    private func fetchAndIndexAllSongs() async {
        songsIndexState = .indexing(0)

        do {
            let allSongs = try await jellyfinService.fetchAllSongs { [weak self] progress in
                self?.songsIndexState = .indexing(progress)
            }

            let songsByAlbum = Dictionary(grouping: allSongs) { $0.albumId }

            for album in albums {
                if let songs = songsByAlbum[album.id] {
                    downloadManager.saveAlbumMetadata(albumId: album.id, album: album, songs: songs, updateIndex: false)
                }
            }

            let indexEntries = allSongs.map {
                SongSearchEntry(id: $0.id, name: $0.name, artistName: $0.artistName, albumName: $0.albumName, albumId: $0.albumId, duration: $0.duration)
            }
            searchManager.replaceSongsIndex(indexEntries)

            downloadManager.donateVocabularyToSiri(albums: albums)

            let now = Date()
            lastIndexedDate = now
            UserDefaults.standard.set(now, forKey: "lastIndexedDate")
            UserDefaults.standard.set(true, forKey: "isSongsIndexed")
            songsIndexState = .indexed
        } catch {
            UserDefaults.standard.set(false, forKey: "isSongsIndexed")
            lastIndexedDate = nil
            UserDefaults.standard.removeObject(forKey: "lastIndexedDate")
            songsIndexState = .notIndexed
        }
    }
}
