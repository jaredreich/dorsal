import SwiftUI
import Intents

@main
struct MusicClient: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var searchManager = SearchManager.shared
    @StateObject private var imageCacheManager = ImageCacheManager.shared
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var jellyfinService = JellyfinService.shared
    @StateObject private var downloadManager = DownloadManager.shared
    @StateObject private var audioPlayer = AudioPlayerManager.shared
    @StateObject private var albumStateManager = AlbumStateManager.shared

    init() {
        requestSiriAuthorization()
        donateMediaPlaybackIntent()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(jellyfinService)
                .environmentObject(downloadManager)
                .environmentObject(audioPlayer)
                .environmentObject(albumStateManager)
                .environmentObject(themeManager)
                .environmentObject(searchManager)
                .environmentObject(imageCacheManager)
                // =============================================================
                // Handle manual Siri app selection via NSUserActivity handoff
                // When user manually selects app from Siri's app list, iOS delivers
                // the intent as a user activity instead of through the extension
                .onContinueUserActivity(NSStringFromClass(INPlayMediaIntent.self)) { userActivity in
                    guard let intent = userActivity.interaction?.intent as? INPlayMediaIntent else { return }
                    let handler = MainAppPlayMediaHandler()
                    handler.resolveMediaItems(for: intent) { _ in
                        handler.handle(intent: intent) { _ in }
                    }
                }
                // =============================================================
        }
    }

    private func requestSiriAuthorization() {
        INPreferences.requestSiriAuthorization { status in
            switch status {
            case .authorized:
                print("Siri authorization granted")
            case .denied:
                print("Siri authorization denied")
            case .restricted:
                print("Siri authorization restricted")
            case .notDetermined:
                print("Siri authorization not determined")
            @unknown default:
                print("Unknown Siri authorization status")
            }
        }
    }

    private func donateMediaPlaybackIntent() {
        let intent = INPlayMediaIntent()
        intent.suggestedInvocationPhrase = "Play music"

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.donate { error in
            if let error = error {
                print("Failed to donate media playback intent: \(error)")
            } else {
                print("Successfully donated media playback intent")
            }
        }
    }
}
