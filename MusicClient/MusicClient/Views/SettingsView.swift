import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var jellyfinService: JellyfinService
    @EnvironmentObject var albumStateManager: AlbumStateManager
    @EnvironmentObject var searchManager: SearchManager
    @State private var showLogoutAlert = false
    @State private var showFullSyncAlert = false
    @State private var albumCount = 0
    @State private var songCount = 0
    @State private var totalHours = 0.0

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Text("settings.sync.last_synced")
                            .foregroundColor(.secondary)
                        Spacer()
                        if albumStateManager.isSyncing {
                            CircularDownloadProgress(progress: albumStateManager.albumSyncProgress)
                                .frame(width: 20, height: 20)
                        } else if let lastSync = albumStateManager.lastSyncDate {
                            Text(lastSync.formatted(date: .abbreviated, time: .shortened))
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }

                    HStack {
                        Text("settings.sync.indexed")
                            .foregroundColor(.secondary)
                        Spacer()
                        switch albumStateManager.songsIndexState {
                        case .notIndexed:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 16))
                        case .indexing(let progress):
                            CircularDownloadProgress(progress: progress)
                                .frame(width: 20, height: 20)
                        case .indexed:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 16))
                        }
                    }

                    Button(action: quickSync) {
                        HStack {
                            Text("settings.sync.quick_sync")
                            Spacer()
                            if albumStateManager.isSyncing {
                                CircularDownloadProgress(progress: albumStateManager.albumSyncProgress)
                                    .frame(width: 20, height: 20)
                            }
                        }
                    }
                    .disabled(albumStateManager.isSyncing)

                    Button(action: { showFullSyncAlert = true }) {
                        HStack {
                            Text("settings.sync.full_sync")
                            Spacer()
                        }
                    }
                    .foregroundColor(.red)
                    .disabled(albumStateManager.isSyncing)
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
                        Text(Versioning.version)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("settings.about.build")
                        Spacer()
                        Text(Versioning.build)
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
            .alert("settings.sync.full_sync", isPresented: $showFullSyncAlert) {
                Button("common.cancel", role: .cancel) {}
                Button("settings.sync.full_sync", role: .destructive) {
                    fullSync()
                }
            } message: {
                Text("settings.sync.full_sync_alert.message")
            }
        }
    }

    private func quickSync() {
        Task {
            try? await albumStateManager.quickSync()
            loadLibraryStats()
        }
    }

    private func fullSync() {
        Task {
            try? await albumStateManager.sync()
            loadLibraryStats()
        }
    }

    private func loadLibraryStats() {
        let albums = searchManager.getAllAlbumsFromMetadata()
        let songEntries = searchManager.getAllSongsIndex()
        albumCount = albums.count
        songCount = songEntries.count
        totalHours = songEntries.compactMap(\.duration).reduce(0, +) / 3600.0
    }
}
