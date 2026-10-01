import Foundation
import UIKit

@MainActor
protocol JellyfinServicing: ObservableObject {
    var authState: AuthState { get set }
    var albums: [Album] { get set }
    var isLoading: Bool { get set }
    var errorMessage: String? { get set }
    var audioQuality: AudioQuality { get set }
    func authenticate(serverUrl: String, username: String, password: String) async throws
    func logout()
    func fetchAllSongs(onProgress: ((Double) -> Void)?) async throws -> [Song]
    func fetchAlbums(onProgress: ((Double) -> Void)?) async throws
    func fetchAlbumsSince(_ date: Date, onProgress: ((Double) -> Void)?) async throws -> [Album]
    func fetchSongIdsSince(_ date: Date) async throws -> [String: String]
    func fetchAlbum(id albumId: String) async throws -> Album?
    func fetchSongs(for albumId: String) async throws -> [Song]
    func getAssetURLRequest(itemId: String) -> URLRequest?
    func getAssetURLRequest(for song: Song) -> URLRequest?
}

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
class JellyfinService: JellyfinServicing {
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

    private let keychainManager: KeychainManaging

    init(keychainManager: KeychainManaging = KeychainManager.shared) {
        self.keychainManager = keychainManager
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
        var header = "MediaBrowser Client=\"MusicClient\", Device=\"iOS\", DeviceId=\"\(deviceId)\", Version=\"\(Versioning.version)\""

        if includeToken, let token = authState.accessToken {
            header += ", Token=\"\(token)\""
        }

        return header
    }

    private func createRequest(url: URL, method: String = "GET", includeToken: Bool = false) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let authHeader = getAuthorizationHeader(includeToken: includeToken)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
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

    func fetchAllSongs(onProgress: ((Double) -> Void)? = nil) async throws -> [Song] {
        guard let serverUrl = authState.serverUrl,
              let userId = authState.userId,
              let _ = authState.accessToken else {
            throw JellyfinError.invalidCredentials
        }

        let pageSize = 500
        var startIndex = 0
        var totalCount: Int? = nil
        var allSongs: [Song] = []
        var lastPageCount = pageSize

        repeat {
            let urlString = "\(serverUrl)/Users/\(userId)/Items?IncludeItemTypes=Audio&Recursive=true&StartIndex=\(startIndex)&Limit=\(pageSize)"

            guard let url = URL(string: urlString) else {
                throw JellyfinError.invalidURL
            }

            let request = createRequest(url: url, includeToken: true)
            let (data, _) = try await URLSession.shared.data(for: request)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["Items"] as? [[String: Any]] else {
                throw JellyfinError.decodingError(NSError(domain: "JellyfinService", code: -1))
            }

            if totalCount == nil {
                totalCount = json["TotalRecordCount"] as? Int
            }

            let pageSongs = items.compactMap { item -> Song? in
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
                let imageUrl: String? = "\(serverUrl)/Items/\(albumId)/Images/Primary"

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

            allSongs.append(contentsOf: pageSongs)
            lastPageCount = items.count
            startIndex += items.count

            if let total = totalCount, total > 0 {
                onProgress?(Double(min(startIndex, total)) / Double(total))
            }
        } while lastPageCount == pageSize && (totalCount == nil || startIndex < totalCount!)

        return allSongs
    }

    func fetchAlbums(onProgress: ((Double) -> Void)? = nil) async throws {
        guard let serverUrl = authState.serverUrl,
              let userId = authState.userId,
              let _ = authState.accessToken else {
            throw JellyfinError.invalidCredentials
        }

        isLoading = true
        defer { isLoading = false }

        let pageSize = 500
        var startIndex = 0
        var totalCount: Int? = nil
        var allAlbums: [Album] = []
        var lastPageCount = pageSize

        repeat {
            let urlString = "\(serverUrl)/Users/\(userId)/Items?IncludeItemTypes=MusicAlbum&Recursive=true&Fields=ProductionYear,DateCreated&StartIndex=\(startIndex)&Limit=\(pageSize)"

            guard let url = URL(string: urlString) else {
                throw JellyfinError.invalidURL
            }

            let request = createRequest(url: url, includeToken: true)
            let (data, _) = try await URLSession.shared.data(for: request)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["Items"] as? [[String: Any]] else {
                throw JellyfinError.decodingError(NSError(domain: "JellyfinService", code: -1))
            }

            if totalCount == nil {
                totalCount = json["TotalRecordCount"] as? Int
            }

            let pageAlbums = items.compactMap { item in parseAlbum(from: item) }

            allAlbums.append(contentsOf: pageAlbums)
            lastPageCount = items.count
            startIndex += items.count

            if let total = totalCount, total > 0 {
                onProgress?(Double(min(startIndex, total)) / Double(total))
            }
        } while lastPageCount == pageSize && (totalCount == nil || startIndex < totalCount!)

        albums = allAlbums
    }

    func fetchAlbumsSince(_ date: Date, onProgress: ((Double) -> Void)? = nil) async throws -> [Album] {
        guard let serverUrl = authState.serverUrl,
              let userId = authState.userId,
              let _ = authState.accessToken else {
            throw JellyfinError.invalidCredentials
        }

        let dateString = ISO8601DateFormatter().string(from: date)
        let pageSize = 500
        var startIndex = 0
        var totalCount: Int? = nil
        var allAlbums: [Album] = []
        var lastPageCount = pageSize

        repeat {
            let urlString = "\(serverUrl)/Users/\(userId)/Items?IncludeItemTypes=MusicAlbum&Recursive=true&Fields=ProductionYear,DateCreated&MinDateLastSaved=\(dateString)&StartIndex=\(startIndex)&Limit=\(pageSize)"

            guard let url = URL(string: urlString) else {
                throw JellyfinError.invalidURL
            }

            let request = createRequest(url: url, includeToken: true)
            let (data, _) = try await URLSession.shared.data(for: request)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["Items"] as? [[String: Any]] else {
                throw JellyfinError.decodingError(NSError(domain: "JellyfinService", code: -1))
            }

            if totalCount == nil {
                totalCount = json["TotalRecordCount"] as? Int
            }

            let pageAlbums = items.compactMap { item in parseAlbum(from: item) }
            allAlbums.append(contentsOf: pageAlbums)
            lastPageCount = items.count
            startIndex += items.count

            if let total = totalCount, total > 0 {
                onProgress?(Double(min(startIndex, total)) / Double(total))
            }
        } while lastPageCount == pageSize && (totalCount == nil || startIndex < totalCount!)

        return allAlbums
    }

    func fetchSongIdsSince(_ date: Date) async throws -> [String: String] {
        guard let serverUrl = authState.serverUrl,
              let userId = authState.userId,
              let _ = authState.accessToken else {
            throw JellyfinError.invalidCredentials
        }

        let dateString = ISO8601DateFormatter().string(from: date)
        let pageSize = 500
        var startIndex = 0
        var totalCount: Int? = nil
        var songAlbumMap: [String: String] = [:]
        var lastPageCount = pageSize

        repeat {
            let urlString = "\(serverUrl)/Users/\(userId)/Items?IncludeItemTypes=Audio&Recursive=true&Fields=&MinDateLastSaved=\(dateString)&StartIndex=\(startIndex)&Limit=\(pageSize)"

            guard let url = URL(string: urlString) else {
                throw JellyfinError.invalidURL
            }

            let request = createRequest(url: url, includeToken: true)
            let (data, _) = try await URLSession.shared.data(for: request)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["Items"] as? [[String: Any]] else {
                throw JellyfinError.decodingError(NSError(domain: "JellyfinService", code: -1))
            }

            if totalCount == nil {
                totalCount = json["TotalRecordCount"] as? Int
            }

            for item in items {
                if let id = item["Id"] as? String,
                   let albumId = item["AlbumId"] as? String {
                    songAlbumMap[id] = albumId
                }
            }

            lastPageCount = items.count
            startIndex += items.count
        } while lastPageCount == pageSize && (totalCount == nil || startIndex < totalCount!)

        return songAlbumMap
    }

    func fetchAlbum(id albumId: String) async throws -> Album? {
        guard let serverUrl = authState.serverUrl,
              let userId = authState.userId,
              let _ = authState.accessToken else {
            throw JellyfinError.invalidCredentials
        }

        let urlString = "\(serverUrl)/Users/\(userId)/Items/\(albumId)"
        guard let url = URL(string: urlString) else {
            throw JellyfinError.invalidURL
        }

        let request = createRequest(url: url, includeToken: true)
        let (data, _) = try await URLSession.shared.data(for: request)

        guard let item = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JellyfinError.decodingError(NSError(domain: "JellyfinService", code: -1))
        }

        return parseAlbum(from: item)
    }

    private func parseAlbum(from item: [String: Any]) -> Album? {
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

    func getAssetURLRequest(itemId: String) -> URLRequest? {
        guard let serverUrl = authState.serverUrl,
            authState.accessToken != nil else { return nil }

        let url: String
        if let bitrate = audioQuality.bitrate {
            url = "\(serverUrl)/Audio/\(itemId)/universal?audioCodec=aac&container=m4a&transcodingContainer=m4a&maxStreamingBitrate=\(bitrate)&transcodingProtocol=http"
        } else {
            url = "\(serverUrl)/Audio/\(itemId)/stream?static=true"
        }

        guard let assetUrl = URL(string: url) else { return nil }
        var request = URLRequest(url: assetUrl)
        let authHeader = getAuthorizationHeader(includeToken: true)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        return request
    }
    
    func getAssetURLRequest(for song: Song) -> URLRequest? {
        return getAssetURLRequest(itemId: song.id)
    }
}
