import Foundation

struct AuthState: Codable {
    var serverUrl: String?
    var userId: String?
    var username: String?
    var accessToken: String?
    var isAuthenticated: Bool {
        serverUrl != nil && accessToken != nil && userId != nil
    }
}

struct LoginCredentials {
    var username: String
    var password: String
}
