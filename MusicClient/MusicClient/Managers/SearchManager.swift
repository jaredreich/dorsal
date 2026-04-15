import Foundation
import Intents

class SearchManager {
    static let shared = SearchManager()

    private let fileManager = FileManager.default
    private let appGroupId = "group.com.jaredreich.shared"

    private var albumsCache: [Album] = []

    private var albumsDirectory: URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
            .appendingPathComponent("Storage/albums", isDirectory: true)
    }

    private var albumsIndexUrl: URL? {
        albumsDirectory?.appendingPathComponent("albums.json")
    }

    private init() {
        loadAlbumsIndex()
    }

    private func loadAlbumsIndex() {
        guard let url = albumsIndexUrl,
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let albums = try? JSONDecoder().decode([Album].self, from: data) else {
            return
        }
        albumsCache = albums
    }

    private func saveAlbumsIndex() {
        guard let url = albumsIndexUrl else { return }
        if let data = try? JSONEncoder().encode(albumsCache) {
            try? data.write(to: url)
        }
    }

    func updateAlbumInIndex(_ album: Album) {
        if let index = albumsCache.firstIndex(where: { $0.id == album.id }) {
            albumsCache[index] = album
        } else {
            albumsCache.append(album)
        }
        saveAlbumsIndex()
    }

    func replaceAlbumsIndex(_ albums: [Album]) {
        albumsCache = albums
        saveAlbumsIndex()
    }

    func getAllAlbumsFromMetadata() -> [Album] {
        return albumsCache
    }

    func getAllSongsFromAlbums(_ albums: [Album]) -> [Song] {
        return albums.flatMap { getSongsForAlbum($0.id) }
    }

    func getSongsForAlbum(_ albumId: String) -> [Song] {
        return loadAlbumMetadata(albumId: albumId)?.songs ?? []
    }

    func searchAlbumsByName(albums: [Album], _ query: String) -> [Album] {
        return albums.filter { fuzzyMatch($0.name, query) }
    }

    func searchAlbumsByArtist(albums: [Album], query: String) -> [Album] {
        return albums.filter { fuzzyMatch($0.artistName, query) }
    }

    func searchSongsByTitle(albums: [Album], query: String) -> [Song] {
        return getAllSongsFromAlbums(albums).filter { fuzzyMatch($0.name, query) }
    }

    func resolveMediaItems(from mediaSearch: INMediaSearch) -> [INPlayMediaMediaItemResolutionResult] {
        let mediaType = mediaSearch.mediaType
        let mediaTypeIsOther = mediaType != .artist && mediaType != .album && mediaType != .song
        let mediaName = mediaSearch.mediaName ?? ""
        let artistName = mediaSearch.artistName ?? ""
        let albumName = mediaSearch.albumName ?? ""

        var mediaTypeString: String {
            switch mediaType {
            case .song: return "song"
            case .album: return "album"
            case .artist: return "artist"
            default: return "other"
            }
        }

        var artistSearchValue = ""
        if (!artistName.isEmpty) {
            artistSearchValue = artistName
        } else if (mediaType == .artist) {
            artistSearchValue = mediaName
        }

        var albumSearchValue = ""
        if (!albumName.isEmpty) {
            albumSearchValue = albumName
        } else if (mediaType == .album) {
            albumSearchValue = mediaName
        }

        var songSearchValue = ""
        if (mediaType == .song) {
            songSearchValue = mediaName
        } else if (
            mediaType == .album &&
            !albumName.isEmpty &&
            mediaName != albumName
        ) {
            songSearchValue = mediaName
        } else if (
            mediaTypeIsOther &&
            !artistName.isEmpty &&
            !albumName.isEmpty &&
            mediaName != artistName &&
            mediaName != albumName
        ) {
            songSearchValue = mediaName
        }

        var otherSearchValue = ""
        if (mediaTypeIsOther) {
            otherSearchValue = mediaName
        }

        var albums = SearchManager.shared.getAllAlbumsFromMetadata()
        var songs = SearchManager.shared.getAllSongsFromAlbums(albums)

        if (!artistSearchValue.isEmpty) {
            songs = songs.filter { song in
                fuzzyMatch(song.artistName, artistSearchValue)
            }
            albums = albums.filter { album in
                fuzzyMatch(album.artistName, artistSearchValue)
            }
        }
        if (!albumSearchValue.isEmpty) {
            songs = songs.filter { song in
                fuzzyMatch(song.albumName, albumSearchValue)
            }
            albums = albums.filter { album in
                fuzzyMatch(album.name, albumSearchValue)
            }
        }
        if (!songSearchValue.isEmpty) {
            songs = songs.filter { song in
                fuzzyMatch(song.name, songSearchValue)
            }
        }

        songs = songs.sorted { $0.name < $1.name }
        albums = albums.sorted { $0.name < $1.name }

        var albumToPlay: Album? = nil
        var songToPlay: Song? = nil

        if (!songSearchValue.isEmpty) {
            // Specific song
            if (!songs.isEmpty) {
                songToPlay = songs.first
            }
        } else if (
            !albumSearchValue.isEmpty &&
            songSearchValue.isEmpty
        ) {
            // Specific album, no specific song
            albumToPlay = albums.first
        } else if (
            !artistSearchValue.isEmpty &&
            albumSearchValue.isEmpty &&
            songSearchValue.isEmpty &&
            otherSearchValue.isEmpty
        ) {
            if (mediaType == .song) {
                // User requested specific artist, "any song"
                songToPlay = songs.randomElement()
            } else {
                // User requested specific artist, "any album" or no other specifics
                albumToPlay = albums.randomElement()
            }
        } else if (!otherSearchValue.isEmpty) {
            // If we got here, then we can search our content but it's not specific.
            // Search everything and prioritize in the order "artist -> album -> song"
            // Artists can have self-titled albums and we shall prefer playing the artist over the song (choosing random album from artist to play)
            // Albums can have self-titled songs and we shall prefer playing the album over the song

            let songsMatch = SearchManager.shared.searchSongsByTitle(albums: albums, query: otherSearchValue)
            let albumsMatch = SearchManager.shared.searchAlbumsByName(albums: albums, otherSearchValue)
            let albumsMatchByArtist = SearchManager.shared.searchAlbumsByArtist(albums: albums, query: otherSearchValue)

            if (!albumsMatchByArtist.isEmpty) {
                // Artist found and prioritized accordingly
                albumToPlay = albumsMatchByArtist.randomElement()
            } else if (!albumsMatch.isEmpty) {
                // Album found and prioritized accordingly
                albumToPlay = albumsMatch.first
            } else if (!songsMatch.isEmpty) {
                // Song found and prioritized accordingly
                songToPlay = songsMatch.first
            }
        } else if (
            artistSearchValue.isEmpty &&
            albumSearchValue.isEmpty &&
            songSearchValue.isEmpty &&
            otherSearchValue.isEmpty
        ) {
            if (mediaType == .song) {
                // User requested "any song"
                songToPlay = songs.randomElement()
            } else {
                // User requested "any music" or "any album" or "any artist"
                albumToPlay = albums.randomElement()
            }
        }

        var items: [INMediaItem] = []

        if let albumToPlay = albumToPlay {
            items = [
                makeMediaItem(
                    type: .album,
                    id: albumToPlay.id,
                    name: albumToPlay.name,
                    artist: albumToPlay.artistName,
                    artworkUrl: albumToPlay.imageUrl
                )
            ]
            return [INPlayMediaMediaItemResolutionResult.success(with: items[0])]
        }

        if let songToPlay = songToPlay {
            items = [
                makeMediaItem(
                    type: .song,
                    id: songToPlay.id,
                    name: songToPlay.name,
                    artist: songToPlay.artistName,
                    artworkUrl: songToPlay.imageUrl
                )
            ]
            return [INPlayMediaMediaItemResolutionResult.success(with: items[0])]
        }

        // If we got here, nothing to play
        return [INPlayMediaMediaItemResolutionResult.unsupported()]
    }

    private func makeMediaItem(
        type: INMediaItemType,
        id: String,
        name: String,
        artist: String,
        artworkUrl: String?
    ) -> INMediaItem {
        let artwork: INImage? = {
            guard let urlString = artworkUrl, let url = URL(string: urlString) else {
                return nil
            }
            return INImage(url: url)
        }()

        return INMediaItem(
            identifier: id,
            title: name,
            type: type,
            artwork: artwork,
            artist: artist
        )
    }

    private func loadAlbumMetadata(albumId: String) -> AlbumMetadata? {
        guard let albumsDir = albumsDirectory else { return nil }
        let url = albumsDir.appendingPathComponent("\(albumId).json")
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(AlbumMetadata.self, from: data) else {
            return nil
        }
        return metadata
    }

    private func fuzzyMatch(_ string: String, _ query: String) -> Bool {
        return string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
