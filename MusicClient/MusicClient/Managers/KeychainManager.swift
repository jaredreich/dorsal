import Foundation
import Security

class KeychainManager {
    static let shared = KeychainManager()

    private let serviceName = "com.jaredreich.music"
    private let serverUrlKey = "serverUrl"
    private let accessTokenKey = "accessToken"
    private let userIdKey = "userId"
    private let usernameKey = "username"

    private init() {}

    func saveServerUrl(_ url: String) -> Bool {
        return save(key: serverUrlKey, value: url)
    }

    func saveAccessToken(_ token: String) -> Bool {
        return save(key: accessTokenKey, value: token)
    }

    func saveUserId(_ userId: String) -> Bool {
        return save(key: userIdKey, value: userId)
    }

    func saveUsername(_ username: String) -> Bool {
        return save(key: usernameKey, value: username)
    }

    func saveAuthState(_ authState: AuthState) -> Bool {
        var success = true
        if let serverUrl = authState.serverUrl {
            success = success && saveServerUrl(serverUrl)
        }
        if let token = authState.accessToken {
            success = success && saveAccessToken(token)
        }
        if let userId = authState.userId {
            success = success && saveUserId(userId)
        }
        if let username = authState.username {
            success = success && saveUsername(username)
        }
        return success
    }

    func getServerUrl() -> String? {
        return retrieve(key: serverUrlKey)
    }

    func getAccessToken() -> String? {
        return retrieve(key: accessTokenKey)
    }

    func getUserId() -> String? {
        return retrieve(key: userIdKey)
    }

    func getUsername() -> String? {
        return retrieve(key: usernameKey)
    }

    func getAuthState() -> AuthState {
        return AuthState(
            serverUrl: getServerUrl(),
            userId: getUserId(),
            username: getUsername(),
            accessToken: getAccessToken()
        )
    }

    func deleteAll() -> Bool {
        var success = true
        success = success && delete(key: serverUrlKey)
        success = success && delete(key: accessTokenKey)
        success = success && delete(key: userIdKey)
        success = success && delete(key: usernameKey)
        return success
    }

    private func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        _ = delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private func retrieve(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    private func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
