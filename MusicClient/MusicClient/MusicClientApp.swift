import SwiftUI
import Intents

@main
struct MusicClient: App {
    @StateObject private var jellyfinService = JellyfinService.shared
    @StateObject private var audioPlayer = AudioPlayerManager.shared
    @StateObject private var albumCoordinator = AlbumStateCoordinator.shared
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Request Siri authorization, critical for intents to work
        requestSiriAuthorization()
        // Donate a generic media playback intent to help iOS recognize the app
        donateMediaPlaybackIntent()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(jellyfinService)
                .environmentObject(audioPlayer)
                .environmentObject(albumCoordinator)
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

class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    static let defaultAccentColor = Color(red: 170/255, green: 92/255, blue: 195/255) // #AA5CC3

    @Published var accentColor: Color

    private init() {
        if let data = UserDefaults.standard.data(forKey: "accentColor"),
           let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) {
            accentColor = Color(uiColor: uiColor)
        } else {
            accentColor = ThemeManager.defaultAccentColor
        }
    }

    func setAccentColor(_ color: Color) {
        accentColor = color
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: UIColor(color), requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "accentColor")
        }
    }
}

extension Color {
    static var appAccent: Color {
        ThemeManager.shared.accentColor
    }
}

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

struct LayoutConstants {
    static let miniPlayerBottomPadding: CGFloat = 70
}
