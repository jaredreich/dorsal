import Foundation
import UIKit

enum JellyfinError: Error {
    case invalidURL
    case invalidCredentials
    case networkError(Error)
    case serverError(String)
    case decodingError(Error)
}

enum AudioQuality: String, CaseIterable, Codable {
    case original = "Original"
    case kbps256 = "256 kbps"
    case kbps192 = "192 kbps"
    case kbps128 = "128 kbps"

    var bitrate: Int? {
        switch self {
        case .original: return nil
        case .kbps256: return 256000
        case .kbps192: return 192000
        case .kbps128: return 128000
        }
    }

    var description: String {
        switch self {
        case .original: return String(localized: "audio_quality.original")
        case .kbps256: return String(localized: "audio_quality.high")
        case .kbps192: return String(localized: "audio_quality.medium")
        case .kbps128: return String(localized: "audio_quality.low")
        }
    }
}

@MainActor
class JellyfinService: ObservableObject {
    static let shared = JellyfinService()

    @Published var authState: AuthState
    @Published var albums: [Album] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var audioQuality: AudioQuality {
        didSet {
            saveAudioQuality()
        }
    }

    private let keychainManager = KeychainManager.shared

    private init() {
        self.authState = keychainManager.getAuthState()
        self.audioQuality = Self.loadAudioQuality()
    }

    private static func loadAudioQuality() -> AudioQuality {
        if let data = UserDefaults.standard.data(forKey: "audioQuality"),
           let quality = try? JSONDecoder().decode(AudioQuality.self, from: data) {
            return quality
        }
        return .kbps128
    }

    private func saveAudioQuality() {
        if let data = try? JSONEncoder().encode(audioQuality) {
            UserDefaults.standard.set(data, forKey: "audioQuality")
        }
    }

    private func getAuthorizationHeader(includeToken: Bool = false) -> String {
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        var header = "MediaBrowser Client=\"MusicClient\", Device=\"iOS\", DeviceId=\"\(deviceId)\", Version=\"\(appVersion)\""

        if includeToken, let token = authState.accessToken {
            header += ", Token=\"\(token)\""
        }

        return header
    }

    private func createRequest(url: URL, method: String = "GET", includeToken: Bool = false) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(getAuthorizationHeader(includeToken: includeToken), forHTTPHeaderField: "X-Emby-Authorization")
        return request
    }

    func authenticate(serverUrl: String, username: String, password: String) async throws {
        guard let url = URL(string: "\(serverUrl)/Users/AuthenticateByName") else {
            throw JellyfinError.invalidURL
        }

        var request = createRequest(url: url, method: "POST", includeToken: false)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "Username": username,
            "Pw": password
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinError.serverError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            throw JellyfinError.invalidCredentials
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["AccessToken"] as? String,
              let user = json["User"] as? [String: Any],
              let userId = user["Id"] as? String else {
            throw JellyfinError.decodingError(NSError(domain: "JellyfinService", code: -1))
        }

        let newAuthState = AuthState(
            serverUrl: serverUrl,
            userId: userId,
            username: username,
            accessToken: accessToken
        )

        DispatchQueue.main.async {
            self.authState = newAuthState
            _ = self.keychainManager.saveAuthState(newAuthState)
        }
    }

    func logout() {
        DispatchQueue.main.async {
            self.authState = AuthState()
            _ = self.keychainManager.deleteAll()
            self.albums = []
        }
    }

    func fetchAllSongs() async throws -> [Song] {
        guard let serverUrl = authState.serverUrl,
              let userId = authState.userId,
              let _ = authState.accessToken else {
            throw JellyfinError.invalidCredentials
        }

        let urlString = "\(serverUrl)/Users/\(userId)/Items?IncludeItemTypes=Audio&Recursive=true"

        guard let url = URL(string: urlString) else {
            throw JellyfinError.invalidURL
        }

        let request = createRequest(url: url, includeToken: true)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let items = json?["Items"] as? [[String: Any]] else {
            throw JellyfinError.decodingError(NSError(domain: "JellyfinService", code: -1))
        }

        return items.compactMap { item -> Song? in
            guard let id = item["Id"] as? String,
                  let title = item["Name"] as? String,
                  let albumName = item["Album"] as? String,
                  let albumId = item["AlbumId"] as? String else {
                return nil
            }

            let artistName = (item["AlbumArtist"] as? String) ?? (item["Artists"] as? [String])?.first ?? "Unknown Artist"
            let duration = (item["RunTimeTicks"] as? Int).map { TimeInterval($0) / 10_000_000 }
            let trackNumber = item["IndexNumber"] as? Int
            let discNumber = item["ParentIndexNumber"] as? Int

            let imageUrl: String?
            if let albumIdForImage = item["AlbumId"] as? String {
                imageUrl = "\(serverUrl)/Items/\(albumIdForImage)/Images/Primary"
            } else {
                imageUrl = nil
            }

            return Song(
                id: id,
                name: title,
                artistName: artistName,
                albumName: albumName,
                albumId: albumId,
                duration: duration,
                trackNumber: trackNumber,
                discNumber: discNumber,
                imageUrl: imageUrl
            )
        }
    }

    func fetchAlbums() async throws {
        guard let serverUrl = authState.serverUrl,
              let userId = authState.userId,
              let _ = authState.accessToken else {
            throw JellyfinError.invalidCredentials
        }

        let urlString = "\(serverUrl)/Users/\(userId)/Items?IncludeItemTypes=MusicAlbum&Recursive=true&Fields=ProductionYear,DateCreated"

        guard let url = URL(string: urlString) else {
            throw JellyfinError.invalidURL
        }

        let request = createRequest(url: url, includeToken: true)

        DispatchQueue.main.async {
            self.isLoading = true
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let items = json?["Items"] as? [[String: Any]] else {
                throw JellyfinError.decodingError(NSError(domain: "JellyfinService", code: -1))
            }

            let fetchedAlbums = items.compactMap { item -> Album? in
                guard let id = item["Id"] as? String,
                      let name = item["Name"] as? String,
                      let albumArtist = item["AlbumArtist"] as? String else {
                    return nil
                }

                let year = item["ProductionYear"] as? Int
                let songCount = item["ChildCount"] as? Int
                let imageUrl = self.getImageUrl(itemId: id)
                let imageTag = (item["ImageTags"] as? [String: String])?["Primary"]

                var dateAdded: Date? = nil
                if let dateString = item["DateCreated"] as? String {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    dateAdded = formatter.date(from: dateString)
                }

                return Album(
                    id: id,
                    name: name,
                    artistName: albumArtist,
                    year: year,
                    imageUrl: imageUrl,
                    songCount: songCount,
                    dateAdded: dateAdded,
                    imageTag: imageTag
                )
            }

            DispatchQueue.main.async {
                self.albums = fetchedAlbums
                self.isLoading = false
            }
        } catch {
            DispatchQueue.main.async {
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
            throw JellyfinError.networkError(error)
        }
    }

    func fetchSongs(for albumId: String) async throws -> [Song] {
        guard let serverUrl = authState.serverUrl,
              let userId = authState.userId,
              let _ = authState.accessToken else {
            throw JellyfinError.invalidCredentials
        }

        let urlString = "\(serverUrl)/Users/\(userId)/Items?ParentId=\(albumId)"

        guard let url = URL(string: urlString) else {
            throw JellyfinError.invalidURL
        }

        let request = createRequest(url: url, includeToken: true)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let items = json?["Items"] as? [[String: Any]] else {
            throw JellyfinError.decodingError(NSError(domain: "JellyfinService", code: -1))
        }

        let songs = items.compactMap { item -> Song? in
            guard let id = item["Id"] as? String,
                  let name = item["Name"] as? String,
                  let albumName = item["Album"] as? String else {
                return nil
            }

            let artistName = (item["Artists"] as? [String])?.first ?? "Unknown Artist"
            let trackNumber = item["IndexNumber"] as? Int
            let discNumber = item["ParentIndexNumber"] as? Int
            let runTimeTicks = item["RunTimeTicks"] as? Int64
            let duration = runTimeTicks != nil ? TimeInterval(runTimeTicks!) / 10_000_000 : nil
            let imageUrl = self.getImageUrl(itemId: albumId)
            return Song(
                id: id,
                name: name,
                artistName: artistName,
                albumName: albumName,
                albumId: albumId,
                duration: duration,
                trackNumber: trackNumber,
                discNumber: discNumber,
                imageUrl: imageUrl
            )
        }

        return songs
    }

    private func getImageUrl(itemId: String) -> String? {
        guard let serverUrl = authState.serverUrl else { return nil }
        return "\(serverUrl)/Items/\(itemId)/Images/Primary?maxHeight=500&quality=90&format=Jpg"
    }

    func getAssetUrl(itemId: String) -> String? {
        guard let serverUrl = authState.serverUrl,
              let token = authState.accessToken,
              let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }

        return audioQuality == .original
            ? "\(serverUrl)/Audio/\(itemId)/stream?static=true&api_key=\(encodedToken)"
            : "\(serverUrl)/Audio/\(itemId)/universal?audioCodec=aac&container=m4a&transcodingContainer=m4a&maxStreamingBitrate=\(audioQuality.bitrate!)&transcodingProtocol=http&api_key=\(encodedToken)"
    }
    
    func getAssetUrl(for song: Song) -> String? {
        return getAssetUrl(itemId: song.id)
    }
}
