import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var jellyfinService: JellyfinService
    @EnvironmentObject var albumCoordinator: AlbumStateCoordinator
    @State private var showLogoutAlert = false
    @State private var isSyncing = false
    @State private var lastSyncDate: Date?
    @State private var albumCount = 0
    @State private var songCount = 0
    @State private var totalHours = 0.0

    var body: some View {
        NavigationView {
            List {
                Section {
                    if let lastSync = lastSyncDate {
                        HStack {
                            Text("settings.sync.last_synced")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(lastSync.formatted(date: .abbreviated, time: .shortened))
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }

                    Button(action: syncNow) {
                        HStack {
                            Text("settings.sync.button")
                            Spacer()
                            if isSyncing {
                                ProgressView()
                            }
                        }
                    }
                    .foregroundColor(.red)
                    .disabled(isSyncing)
                } header: {
                    Text("settings.sync.header")
                } footer: {
                    Text("settings.sync.footer")
                }

                Section {
                    NavigationLink(destination: AppearanceSettingsView()) {
                        Text("settings.appearance.title")
                    }
                    NavigationLink(destination: EqualizerSettingsView()) {
                        Text("settings.equalizer.title")
                    }
                    NavigationLink(destination: StorageSettingsView()) {
                        Text("settings.storage.title")
                    }
                }

                Section("settings.library.header") {
                    HStack {
                        Text("settings.library.albums")
                        Spacer()
                        Text(verbatim: "\(albumCount)")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("settings.library.songs")
                        Spacer()
                        Text(verbatim: "\(songCount)")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("settings.library.total_duration")
                        Spacer()
                        Text(String(format: "%.1f hours", totalHours))
                            .foregroundColor(.secondary)
                    }
                }

                Section("settings.account.header") {
                    if let serverUrl = jellyfinService.authState.serverUrl {
                        HStack {
                            Text("settings.account.server")
                            Spacer()
                            Text(serverUrl)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .truncationMode(.middle)
                        }
                    }

                    if let username = jellyfinService.authState.username {
                        HStack {
                            Text("settings.account.user")
                            Spacer()
                            Text(username)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        }
                    }

                    Button(action: { showLogoutAlert = true }) {
                        Text("settings.account.sign_out")
                            .foregroundColor(.red)
                    }
                }

                Section("settings.about.header") {
                    HStack {
                        Text("settings.about.version")
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("settings.about.build")
                        Spacer()
                        Text(appBuild)
                            .foregroundColor(.secondary)
                    }
                    NavigationLink(destination: CreditsView()) {
                        Text("settings.about.credits")
                    }
                }
            }
            .navigationTitle("settings.title")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadLastSyncDate()
                loadLibraryStats()
            }
            .alert("settings.account.sign_out", isPresented: $showLogoutAlert) {
                Button("common.cancel", role: .cancel) {}
                Button("settings.account.sign_out", role: .destructive) {
                    jellyfinService.logout()
                }
            } message: {
                Text("settings.account.sign_out_alert.message")
            }
        }
    }

    private func syncNow() {
        isSyncing = true

        Task {
            do {
                albumCoordinator.loadCachedAlbums()
                try await albumCoordinator.fetchAlbums()

                let now = Date()
                lastSyncDate = now
                UserDefaults.standard.set(now, forKey: "lastSyncDate")

                isSyncing = false
            } catch {
                // Show error but still stop syncing
                isSyncing = false
            }
        }
    }

    private func loadLastSyncDate() {
        if let date = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date {
            lastSyncDate = date
        }
    }

    private func loadLibraryStats() {
        let albums = SearchManager.shared.getAllAlbumsFromMetadata()
        let songs = SearchManager.shared.getAllSongsFromAlbums(albums)
        albumCount = albums.count
        songCount = songs.count
        totalHours = songs.compactMap(\.duration).reduce(0, +) / 3600.0
    }
}
