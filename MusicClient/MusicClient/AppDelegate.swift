import UIKit
import AVFoundation
import MediaPlayer
import Intents

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Configure audio session for playback
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // TODO: handle this
        }

        // Make app discoverable by CarPlay
        setupRemoteCommandCenter()

        return true
    }

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Enable basic commands so CarPlay can discover the app
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
    }

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        if intent is INPlayMediaIntent {
            return MainAppPlayMediaHandler()
        }

        return nil
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let sceneConfig = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            sceneConfig.delegateClass = CarPlaySceneDelegate.self
            return sceneConfig
        } else {
            let sceneConfig = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
            return sceneConfig
        }
    }
}

class MainAppPlayMediaHandler: NSObject, INPlayMediaIntentHandling {
    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        guard let mediaSearch = intent.mediaSearch else {
            completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            return
        }

        completion(SearchManager.shared.resolveMediaItems(from: mediaSearch))
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        // When the extension uses .continueInApp, iOS resolves mediaItems via
        // resolveMediaItems() before reaching here.
        // Play the pre-chosen item directly.
        if let mediaItems = intent.mediaItems, !mediaItems.isEmpty {
            handleResolvedMedia(mediaItems: mediaItems, completion: completion)
            return
        }

        // No resolved items, resolution must have failed
        completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
    }

    private func handleResolvedMedia(
        mediaItems: [INMediaItem],
        completion: @escaping (INPlayMediaIntentResponse) -> Void
    ) {
        Task { @MainActor in
            await self.playSelectedItem(mediaItems[0])
            completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
        }
    }

    @MainActor
    private func playSelectedItem(_ item: INMediaItem) async {
        guard let identifier = item.identifier else { return }

        if item.type == .album {
            let songs = SearchManager.shared.getSongsForAlbum(identifier)
            guard !songs.isEmpty else { return }
            AudioPlayerManager.shared.play(queue: songs.sortedByTrack(), startIndex: 0)
        } else if item.type == .song {
            let allAlbums = SearchManager.shared.getAllAlbumsFromMetadata()
            let allSongs = SearchManager.shared.getAllSongsFromAlbums(allAlbums)
            if let song = allSongs.first(where: { $0.id == identifier }) {
                let sortedSongs = SearchManager.shared.getSongsForAlbum(song.albumId).sortedByTrack()
                if let songIndex = sortedSongs.firstIndex(where: { $0.id == identifier }) {
                    AudioPlayerManager.shared.play(queue: sortedSongs, startIndex: songIndex)
                }
            }
        }
    }
}
