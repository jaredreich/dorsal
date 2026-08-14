import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var albumStateManager: AlbumStateManager
    @EnvironmentObject var audioPlayer: AudioPlayerManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var searchManager: SearchManager
    @State private var isLoading = false
    @State private var showSettings = false
    @AppStorage("selectedFilter") private var selectedFilter: FilterOption = .library
    @State private var searchText = ""
    @State private var albumIdsWithMatchingSongs: Set<String> = []
    @State private var randomAlbum: Album?

    private var filteredAlbums: [Album] {
        let filtered = albumStateManager.getFilteredAlbums(
            filter: selectedFilter.rawValue
        )

        if searchText.isEmpty {
            return filtered
        } else {
            return filtered.filter { album in
                fuzzyMatch(album.name, searchText) ||
                fuzzyMatch(album.artistName, searchText) ||
                albumIdsWithMatchingSongs.contains(album.id)
            }
        }
    }

    private var emptyStateIcon: String {
        if !searchText.isEmpty {
            return "magnifyingglass"
        }

        switch selectedFilter {
        case .library:
            return "music.note"
        case .latestAdded:
            return "calendar.badge.plus"
        case .recentlyPlayed:
            return "clock"
        case .offline:
            return "arrow.down.circle"
        }
    }

    private var emptyStateMessage: LocalizedStringKey {
        if !searchText.isEmpty {
            return "library.empty.no_results"
        }

        switch selectedFilter {
        case .library:
            return "library.empty.library"
        case .latestAdded:
            return "library.empty.latest_added"
        case .recentlyPlayed:
            return "library.empty.recently_played"
        case .offline:
            return "library.empty.offline"
        }
    }

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("library.loading")
                } else if filteredAlbums.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: emptyStateIcon)
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text(emptyStateMessage)
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    List {
                        if selectedFilter == .recentlyPlayed {
                            ForEach(filteredAlbums) { album in
                                NavigationLink(destination: AlbumDetailView(album: album)) {
                                    AlbumRowView(
                                        album: album,
                                        hasCachedSongs: albumStateManager.albumsWithCachedSongs.contains(album.id)
                                    )
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        removeFromRecentlyPlayed(album)
                                    } label: {
                                        Label("library.remove", systemImage: "trash")
                                    }
                                }
                            }
                            .onMove { source, destination in
                                moveRecentlyPlayedAlbum(from: source, to: destination)
                            }
                        } else {
                            // Leave "Random Album" hidden for now (it's more of a CarPlay-only feature)
                            /*
                            if selectedFilter == .library, searchText.isEmpty, !filteredAlbums.isEmpty {
                                Button {
                                    randomAlbum = filteredAlbums.randomElement()
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "dice")
                                            .font(.title2)
                                            .foregroundColor(.white)
                                            .frame(width: 60, height: 60)
                                            .background(
                                                LinearGradient(
                                                    colors: [Color(.systemGray), Color(.systemGray2)],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .cornerRadius(8)
                            
                                        Text("library.random_album")
                                            .font(.headline)
                                            .foregroundColor(.primary)
                            
                                        Spacer()
                            
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(Color(.tertiaryLabel))
                                    }
                                    .padding(.vertical, 4)
                                }
                                .background(
                                    NavigationLink(
                                        destination: AlbumDetailView(album: randomAlbum ?? filteredAlbums[0])
                                            .id(randomAlbum?.id),
                                        label: { EmptyView() }
                                    )
                                    .opacity(0)
                                )
                            }
                            */
                            ForEach(filteredAlbums) { album in
                                NavigationLink(destination: AlbumDetailView(album: album)) {
                                    AlbumRowView(
                                        album: album,
                                        hasCachedSongs: albumStateManager.albumsWithCachedSongs.contains(album.id)
                                    )
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .safeAreaInset(edge: .bottom) {
                        if audioPlayer.currentSong != nil {
                            Color.clear.frame(height: Layout.miniPlayerBottomPadding)
                        }
                    }
                }
            }
            .navigationTitle(selectedFilter.localizedName)
            .navigationBarTitleDisplayMode(.inline)
            .conditionallySearchable(
                isEnabled: albumStateManager.songsIndexState == .indexed,
                text: $searchText,
                prompt: Text("library.search_prompt")
            )
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        ForEach(FilterOption.allCases, id: \.self) { option in
                            Button {
                                selectedFilter = option
                            } label: {
                                HStack {
                                    Image(systemName: option.icon)
                                    Text(option.localizedName)
                                    if selectedFilter == option {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: selectedFilter.icon)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(albumStateManager)
            }
        }
        .onAppear {
            albumStateManager.loadCachedAlbums()
            audioPlayer.restorePersistedState()
        }
        .onChange(of: searchText) { newValue in
            updateSongSearchIndex(query: newValue)
        }
        .onChange(of: albumStateManager.songsIndexState == .indexed) { isIndexed in
            if !isIndexed { searchText = "" }
        }
    }

    private func updateSongSearchIndex(query: String) {
        guard !query.isEmpty else {
            albumIdsWithMatchingSongs = []
            return
        }
        let allAlbums = searchManager.getAllAlbumsFromMetadata()
        let albumMatched = Set(allAlbums.filter { fuzzyMatch($0.name, query) || fuzzyMatch($0.artistName, query) }.map { $0.id })
        albumIdsWithMatchingSongs = searchManager.getAlbumIdsMatchingSongs(query: query, excluding: albumMatched)
    }

    private func removeFromRecentlyPlayed(_ album: Album) {
        downloadManager.removeFromRecentlyPlayed(albumId: album.id)
    }

    private func moveRecentlyPlayedAlbum(from source: IndexSet, to destination: Int) {
        var albumIds = filteredAlbums.map { $0.id }
        albumIds.move(fromOffsets: source, toOffset: destination)
        downloadManager.reorderRecentlyPlayed(newOrder: albumIds)
    }

    private func fuzzyMatch(_ string: String, _ query: String) -> Bool {
        return string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

struct AlbumRowView: View {
    let album: Album
    let hasCachedSongs: Bool
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        HStack(spacing: 12) {
            AlbumArtView(
                imageUrl: album.imageUrl,
                albumId: album.id,
                size: 60
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(album.name)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Text(album.artistName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            Spacer()

            if downloadManager.downloadingAlbumIds.contains(album.id) {
                CircularDownloadProgress(progress: downloadManager.albumDownloadProgress(albumId: album.id))
                    .frame(width: 20, height: 20)
            } else if downloadManager.isPinned(albumId: album.id) {
                Image(systemName: "circle.fill")
                    .foregroundColor(.appAccent)
                    .font(.system(size: 8))
            } else if hasCachedSongs {
                Image(systemName: "circle.fill")
                    .foregroundColor(.gray)
                    .font(.system(size: 8))
            }
        }
        .padding(.vertical, 4)
    }
}

private extension View {
    @ViewBuilder
    func conditionallySearchable(isEnabled: Bool, text: Binding<String>, prompt: Text) -> some View {
        if isEnabled {
            self.searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        } else {
            self
        }
    }
}

