import CarPlay
import Foundation
import AVFoundation
import MediaPlayer
import Combine

@MainActor
class CarPlayTemplateManager: NSObject {
    private var interfaceController: CPInterfaceController?
    private let jellyfinService = JellyfinService.shared
    private let albumCoordinator = AlbumStateCoordinator.shared
    private let audioPlayer = AudioPlayerManager.shared
    private let imageCache = ImageCacheManager.shared
    private let downloadManager = DownloadManager.shared
    private var nowPlayingObserver: NSObjectProtocol?
    private var playbackObserver: NSObjectProtocol?
    private var authStateObserver: AnyCancellable?
    private var shouldNavigateToNowPlayingOnStart = false
    private var playbackStateObserver: AnyCancellable?
    private var loadingSongItem: CPListItem?
    private var songItems: [String: CPListItem] = [:]
    private var albumItems: [String: [CPListItem]] = [:]
    private var currentSongObserver: AnyCancellable?
    private var tabBarTemplate: CPTabBarTemplate?

    func connect(_ interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        self.interfaceController?.delegate = self

        addObservers()
        setupRootTemplate()
        observeAuthStateChanges()
    }

    func disconnect() {
        nowPlayingObserver = nil
        playbackObserver = nil
        authStateObserver = nil
        playbackStateObserver = nil
        currentSongObserver = nil
        loadingSongItem = nil
        songItems.removeAll()
        albumItems.removeAll()
        tabBarTemplate = nil
        interfaceController = nil
    }

    private func observeAuthStateChanges() {
        authStateObserver = jellyfinService.$authState
            .sink { [weak self] authState in
                Task { @MainActor in
                    // When auth state changes, refresh the root template
                    // (user logs in on the phone, so carplay should refresh)
                    self?.setupRootTemplate()
                }
            }
    }

    private func createPlaceholderImage(icon: String = "music.note") -> UIImage {
        let size = CGSize(width: 60, height: 60)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let colors = [UIColor.systemGray.cgColor, UIColor.systemGray2.cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])

            let iconSize: CGFloat = 30
            let iconOrigin = CGPoint(x: (size.width - iconSize) / 2, y: (size.height - iconSize) / 2)
            let iconRect = CGRect(origin: iconOrigin, size: CGSize(width: iconSize, height: iconSize))

            if let iconImage = UIImage(systemName: icon)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                iconImage.draw(in: iconRect)
            }
        }
    }

    private func setupRootTemplate() {
        // Check if user is authenticated
        guard jellyfinService.authState.serverUrl != nil,
              jellyfinService.authState.userId != nil,
              jellyfinService.authState.accessToken != nil else {
            // Show message to connect to Jellyfin server
            createUnauthenticatedTemplate()
            return
        }

        // Only load cached albums without fetching from server
        albumCoordinator.loadCachedAlbums()
        createRootTemplate()
    }

    private func createUnauthenticatedTemplate() {
        let item = CPListItem(
            text: String(localized: "carplay.unauthenticated.title"),
            detailText: String(localized: "carplay.unauthenticated.message")
        )
        // .none makes it non-clickable
        item.accessoryType = .none

        let section = CPListSection(items: [item])
        let template = CPListTemplate(title: String(localized: "general.app_name"), sections: [section])

        interfaceController?.setRootTemplate(template, animated: true, completion: nil)
    }

    private func createRootTemplate() {
        // CPNowPlayingTemplate should NOT be in a tab bar
        // it's managed automatically by carplay when audio is playing,
        // just register as an observer
        CPNowPlayingTemplate.shared.add(self)

        // The below code enables the "Up Next" queue button on the Now Playing view
        // this functionality does not work well, so leaving it out
        // =============================================================
        // CPNowPlayingTemplate.shared.isUpNextButtonEnabled = true
        // CPNowPlayingTemplate.shared.upNextTitle = String(localized: "carplay.queue.title")
        // =============================================================

        // Clear existing album items before recreating tabs
        albumItems.removeAll()

        // Create tabs for different filters (it appears the carplay max is 4)
        let libraryTemplate = createLibraryTemplate(filter: FilterOption.library)
        let latestTemplate = createLibraryTemplate(filter: FilterOption.latestAdded)
        let recentTemplate = createLibraryTemplate(filter: FilterOption.recentlyPlayed)
        let offlineTemplate = createLibraryTemplate(filter: FilterOption.offline)
        let templates = [recentTemplate, libraryTemplate, latestTemplate, offlineTemplate]

        // Create the tab bar with all the templates
        let tabBar = CPTabBarTemplate(templates: templates)
        tabBar.delegate = self
        self.tabBarTemplate = tabBar

        // Set it as the root template
        interfaceController?.setRootTemplate(tabBar, animated: true) { _, _ in
            // =============================================================
            // TODO: should this be removed? (doesn't really work in real life)
            // restore previously selected tab using iOS 17+ select() method after template is set
            /*
            // NOTE: device-specific logic
            if #available(iOS 17.0, *) {
                if let savedFilterName = UserDefaults.standard.string(forKey: "carPlaySelectedFilter") {
                    // Find the template with matching title
                    if let selectedTemplate = templates.first(where: { $0.title == savedFilterName }) {
                        tabBar.select(selectedTemplate)
                    }
                }
            }
            */
            // =============================================================
        }
    }

    private func createLibraryTemplate(filter: FilterOption) -> CPListTemplate {
        let albums = albumCoordinator.getFilteredAlbums(
            filter: filter.rawValue,
            recentlyPlayedAlbumIds: audioPlayer.recentlyPlayedAlbumIds
        )

        let shouldUseAlphabeticalSections = (filter == .library || filter == .offline)

        let sections: [CPListSection]

        if shouldUseAlphabeticalSections {
            let grouped = Dictionary(grouping: albums) { album -> String in
                let firstChar = album.artistName.prefix(1).uppercased()
                if firstChar.rangeOfCharacter(from: .letters) != nil {
                    return firstChar
                } else {
                    return "#"
                }
            }

            let sortedSections = grouped.sorted { $0.key < $1.key }

            // This adds the "Random Album" row as the first section for Library tab only
            // =============================================================
            var allSections: [CPListSection] = []
            if filter == .library, !albums.isEmpty {
                let randomItem = CPListItem(text: String(localized: "library.random_album"), detailText: nil)
                randomItem.setImage(createPlaceholderImage(icon: "dice"))
                randomItem.handler = { [weak self] _, completion in
                    guard let self = self, let randomAlbum = albums.randomElement() else {
                        completion()
                        return
                    }
                    self.handleAlbumSelection(randomAlbum)
                    completion()
                }
                allSections.append(CPListSection(items: [randomItem]))
            }
            // =============================================================

            // Maps the sections so that the letters are read for each letter for the CPListSection
            allSections += sortedSections.map { letter, albumsInSection in
                let items = albumsInSection.map { album in
                    createAlbumItem(album)
                }
                return CPListSection(items: items, header: letter, sectionIndexTitle: letter)
            }

            sections = allSections
        } else {
            let items = albums.map { album in
                createAlbumItem(album)
            }
            sections = [CPListSection(items: items)]
        }

        let template = CPListTemplate(title: filter.localizedString, sections: sections)

        // NOTE: device-specific logic
        if #available(iOS 26.0, *) {
            template.tabTitle = ""
        } else {
            template.tabTitle = filter.localizedString
        }
        template.tabImage = UIImage(systemName: filter.icon)

        return template
    }

    private func createAlbumItem(_ album: Album) -> CPListItem {
        let item = CPListItem(text: album.name, detailText: album.artistName)

        // Store album item for playback state updates
        // (append to array to track multiple instances across tabs)
        if albumItems[album.id] == nil {
            albumItems[album.id] = []
        }
        albumItems[album.id]?.append(item)

        // Set initial playing state if current song belongs to this album
        if let currentSong = audioPlayer.currentSong,
           currentSong.albumId == album.id,
           audioPlayer.isPlaying {
            item.isPlaying = true
        }

        let localUrl = downloadManager.getAlbumArtUrl(for: album.id)
        let localUrlIfExists = FileManager.default.fileExists(atPath: localUrl.path) ? localUrl : nil

        if let cachedImage = imageCache.getCachedImage(localUrl: localUrlIfExists, remoteUrlString: album.imageUrl) {
            item.setImage(cachedImage)
        } else {
            item.setImage(createPlaceholderImage())

            Task {
                let image = await imageCache.loadImage(
                    localUrl: localUrlIfExists,
                    remoteUrlString: album.imageUrl
                )

                await MainActor.run {
                    if let image = image {
                        item.setImage(image)
                    }
                }
            }
        }

        item.handler = { [weak self] _, completion in
            self?.handleAlbumSelection(album)
            completion()
        }

        return item
    }

    private func handleAlbumSelection(_ album: Album) {
        Task {
            do {
                let songs = try await downloadManager.loadSongsForAlbum(album.id, album: album)
                await MainActor.run {
                    self.showAlbumDetail(album: album, songs: songs)
                }
            } catch {
                // TODO: handle this
            }
        }
    }

    private func showAlbumDetail(album: Album, songs: [Song]) {
        // Clear previous song items when showing new album
        songItems.removeAll()

        let hasMultipleDiscs = album.hasMultipleDiscs(songs: songs)

        var detailParts: [String] = []
        if let year = album.year {
            detailParts.append(String(year))
        }
        detailParts.append("\(songs.count) \(String(localized: "general.tracks"))")
        detailParts.append("\(songs.totalMinutes) \(String(localized: "album.minutes"))")
        let detailText = detailParts.joined(separator: " · ")

        let playAllItem = CPListItem(
            text: "▶ \(String(localized: "album.play"))",
            detailText: detailText
        )

        if let currentSong = audioPlayer.currentSong,
           currentSong.albumId == album.id,
           audioPlayer.isPlaying {
            playAllItem.isPlaying = true
        }

        let localUrl = downloadManager.getAlbumArtUrl(for: album.id)
        let localUrlIfExists = FileManager.default.fileExists(atPath: localUrl.path) ? localUrl : nil

        if let cachedImage = imageCache.getCachedImage(localUrl: localUrlIfExists, remoteUrlString: album.imageUrl) {
            playAllItem.setImage(cachedImage)
        } else {
            playAllItem.setImage(createPlaceholderImage())

            Task {
                let image = await imageCache.loadImage(
                    localUrl: localUrlIfExists,
                    remoteUrlString: album.imageUrl
                )

                await MainActor.run {
                    if let image = image {
                        playAllItem.setImage(image)
                    }
                }
            }
        }

        playAllItem.handler = { [weak self] _, completion in
            guard let self = self else {
                completion()
                return
            }

            // Show cloud icon on first song if not cached
            // (this doesn't seem to work in real life)
            if let firstSong = songs.first {
                self.showCloudIconIfNeeded(for: firstSong)
            }

            self.playSongs(songs, startIndex: 0)
            completion()
        }

        var sections: [CPListSection] = []

        if hasMultipleDiscs {
            // First section with Play button only
            sections.append(CPListSection(items: [playAllItem]))

            // Group songs by disc
            let groupedByDisc = album.groupedByDisc(songs: songs)
            let sortedDiscNumbers = album.sortedDiscNumbers(songs: songs)

            // Create section for each disc
            for discNumber in sortedDiscNumbers {
                guard let discSongs = groupedByDisc[discNumber] else { continue }

                let discItems = discSongs.map { song -> CPListItem in
                    let trackNumber = song.trackNumber ?? 1
                    let item = CPListItem(
                        text: "\(trackNumber). \(song.name)",
                        detailText: song.artistName
                    )
                    createSongItemHandler(for: song, in: songs, item: item)
                    return item
                }

                let discSection = CPListSection(items: discItems, header: "\(String(localized: "general.disc")) \(discNumber)", sectionIndexTitle: nil)
                sections.append(discSection)
            }
        } else {
            // Single disc, use normal setup
            let items = songs.enumerated().map { index, song -> CPListItem in
                let item = CPListItem(
                    text: "\(index + 1). \(song.name)",
                    detailText: song.artistName
                )
                createSongItemHandler(for: song, in: songs, item: item)
                return item
            }

            let allItems = [playAllItem] + items
            sections.append(CPListSection(items: allItems))
        }

        let template = CPListTemplate(title: album.name, sections: sections)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func createSongItemHandler(for song: Song, in songs: [Song], item: CPListItem) {
        // Store the item for later playback state updates
        songItems[song.id] = item

        // Update playing state if this is the current song
        if audioPlayer.currentSong?.id == song.id && audioPlayer.isPlaying {
            item.isPlaying = true
        }

        item.handler = { [weak self] _, completion in
            guard let self = self else {
                completion()
                return
            }

            self.showCloudIconIfNeeded(for: song)
            self.playSongs(songs, startIndex: songs.firstIndex(where: { $0.id == song.id }) ?? 0)
            completion()
        }
    }

    private func showCloudIconIfNeeded(for song: Song) {
        let isCached = downloadManager.isCached(songId: song.id)
        if !isCached, let songItem = songItems[song.id] {
            songItem.accessoryType = .cloud
            loadingSongItem = songItem
        }
    }

    private func playSongs(_ songs: [Song], startIndex: Int) {
        // Set flag to navigate to Now Playing once playback actually starts
        shouldNavigateToNowPlayingOnStart = true

        audioPlayer.play(queue: songs, startIndex: startIndex)
    }

    private func addObservers() {
        CPNowPlayingTemplate.shared.add(self)

        playbackObserver = NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: nil,
            queue: .main
        ) { _ in
            // TODO: handle this (playback state changed)
        }

        nowPlayingObserver = NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: nil,
            queue: .main
        ) { _ in
            // TODO: handle this (now playing item changed)
        }

        // Observe isPlaying state to navigate to Now Playing when playback actually starts
        playbackStateObserver = audioPlayer.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] isPlaying in
                guard let self = self else { return }

                if isPlaying {
                    // Clear cloud accessory from song item
                    if let loadingItem = self.loadingSongItem {
                        loadingItem.accessoryType = .none
                        self.loadingSongItem = nil
                    }

                    if self.shouldNavigateToNowPlayingOnStart {
                        self.shouldNavigateToNowPlayingOnStart = false

                        Task { @MainActor in
                            self.interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                        }
                    }
                }

                self.updatePlayingState()
            }

        // Observe current song changes to update playing state
        currentSongObserver = audioPlayer.$currentSong
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updatePlayingState()
            }
    }

    private func updatePlayingState() {
        let currentSongId = audioPlayer.currentSong?.id
        let currentAlbumId = audioPlayer.currentSong?.albumId
        let isPlaying = audioPlayer.isPlaying

        // Update cloud accessory, show on currently loading song, hide on others
        for (songId, item) in songItems {
            let isCurrentSong = (songId == currentSongId)
            item.isPlaying = (isCurrentSong && isPlaying)

            // Show cloud icon if this song is next and not cached
            if isCurrentSong && !isPlaying {
                let isCached = downloadManager.isCached(songId: songId)
                if !isCached {
                    item.accessoryType = .cloud
                } else {
                    item.accessoryType = .none
                }
            } else if isCurrentSong && isPlaying {
                // Clear cloud when song starts playing
                item.accessoryType = .none
            }
        }

        // Update all album items (each album may have multiple items across different tabs)
        for (albumId, items) in albumItems {
            for item in items {
                item.isPlaying = (albumId == currentAlbumId && isPlaying)
            }
        }

    }
}

extension CarPlayTemplateManager: CPTabBarTemplateDelegate {
    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        // Save the selected tab by its title (filter name)
        if let listTemplate = selectedTemplate as? CPListTemplate {
            UserDefaults.standard.set(listTemplate.title, forKey: "carPlaySelectedFilter")
        }
    }
}

extension CarPlayTemplateManager: CPInterfaceControllerDelegate {
    nonisolated func templateWillAppear(_ template: CPTemplate, animated: Bool) {
        // TODO: handle this (template will appear)
    }

    nonisolated func templateDidAppear(_ template: CPTemplate, animated: Bool) {
        // TODO: handle this (template did appear)
    }

    nonisolated func templateWillDisappear(_ template: CPTemplate, animated: Bool) {
        // TODO: handle this (template will disappear)
    }

    nonisolated func templateDidDisappear(_ template: CPTemplate, animated: Bool) {
        // TODO: handle this (template did disappear)
    }
}

extension CarPlayTemplateManager: CPNowPlayingTemplateObserver {
    // Leaving Up Next feature out for now
    /*
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        // Show the queue of songs
        Task { @MainActor in
            if !self.audioPlayer.queue.isEmpty {
                let items = self.audioPlayer.queue.map { song -> CPListItem in
                    let item = CPListItem(text: song.name, detailText: song.artistName)
                    item.isPlaying = (song.id == self.audioPlayer.currentSong?.id)
                    return item
                }

                let template = CPListTemplate(title: String(localized: "carplay.queue.title"), sections: [CPListSection(items: items)])
                self.interfaceController?.pushTemplate(template, animated: true, completion: nil)
            }
        }
    }
    */

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        // Could implement artist view here
    }
}
