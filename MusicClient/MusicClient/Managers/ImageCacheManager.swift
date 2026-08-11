import Foundation
import Combine
import UIKit

protocol ImageCaching {
    func getCachedImage(localUrl: URL?, remoteUrlString: String?) -> UIImage?
    func loadLocalImageSync(from url: URL) -> UIImage?
    func loadLocalImage(from url: URL) async -> UIImage?
    func loadRemoteImage(from url: URL) async -> UIImage?
    func loadImage(localUrl: URL?, remoteUrlString: String?, saveToUrl: URL?) async -> UIImage?
    func preloadImage(from url: URL)
    func clearCache()
}

// Unified image caching system for both local and remote images
class ImageCacheManager: ImageCaching, ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    static let shared = ImageCacheManager()

    // In-memory cache with automatic memory pressure handling
    private let memoryCache: NSCache<NSString, UIImage>

    // URLSession for remote image downloads
    private let urlSession: URLSession

    private init() {
        // Configure memory cache
        self.memoryCache = NSCache<NSString, UIImage>()
        self.memoryCache.countLimit = 5000 // Max 5000 images in memory
        self.memoryCache.totalCostLimit = 1024 * 1024 * 1024 // 1GB limit

        // Configure URLSession with no disk cache (album art is persisted to Storage/artwork/)
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 50 * 1024 * 1024, // 50MB memory cache
            diskCapacity: 0
        )
        self.urlSession = URLSession(configuration: config)

        // Observe memory warnings to clear cache
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clearMemoryCacheOnWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func clearMemoryCacheOnWarning() {
        memoryCache.removeAllObjects()
    }

    // Synchronously check if image is in memory cache
    // Returns image immediately if cached, nil otherwise
    func getCachedImage(localUrl: URL? = nil, remoteUrlString: String? = nil) -> UIImage? {
        // Try local URL cache first
        if let localUrl = localUrl {
            let cacheKey = localUrl.absoluteString as NSString
            if let cachedImage = memoryCache.object(forKey: cacheKey) {
                return cachedImage
            }
        }

        // Try remote URL cache
        if let remoteUrlString = remoteUrlString {
            let cacheKey = remoteUrlString as NSString
            if let cachedImage = memoryCache.object(forKey: cacheKey) {
                return cachedImage
            }
        }

        return nil
    }

    func loadLocalImageSync(from url: URL) -> UIImage? {
        let cacheKey = url.absoluteString as NSString
        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            return cachedImage
        }
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            return nil
        }
        memoryCache.setObject(image, forKey: cacheKey)
        return image
    }

    // Load image from local file URL
    func loadLocalImage(from url: URL) async -> UIImage? {
        let cacheKey = url.absoluteString as NSString

        // Check memory cache first
        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            return cachedImage
        }

        // Load from disk on background thread
        let image = await Task.detached(priority: .userInitiated) { [weak self] () -> UIImage? in
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else {
                return nil
            }

            // Cache in memory
            self?.memoryCache.setObject(image, forKey: cacheKey)

            return image
        }.value

        return image
    }

    // Load image from remote URL
    func loadRemoteImage(from url: URL) async -> UIImage? {
        let cacheKey = url.absoluteString as NSString

        // Check memory cache first
        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            return cachedImage
        }

        // Download from network
        do {
            let (data, _) = try await urlSession.data(from: url)

            guard let image = UIImage(data: data) else {
                return nil
            }

            // Cache in memory
            memoryCache.setObject(image, forKey: cacheKey)

            return image
        } catch {
            return nil
        }
    }

    // Load image with automatic local/remote handling
    // If saveToUrl is provided and image is fetched from remote, the original data will be persisted to that path
    func loadImage(localUrl: URL? = nil, remoteUrlString: String? = nil, saveToUrl: URL? = nil) async -> UIImage? {
        // Try local first if available
        if let localUrl = localUrl {
            if let localImage = await loadLocalImage(from: localUrl) {
                return localImage
            }
        }

        // Fall back to remote, fetch raw data to preserve original format
        if let remoteUrlString = remoteUrlString,
           let remoteUrl = URL(string: remoteUrlString) {
            do {
                let (data, _) = try await urlSession.data(from: remoteUrl)

                guard let image = UIImage(data: data) else { return nil }

                // Cache in memory
                let cacheKey = remoteUrl.absoluteString as NSString
                memoryCache.setObject(image, forKey: cacheKey)

                // Persist original bytes to disk for future offline use
                if let saveUrl = saveToUrl {
                    Task.detached(priority: .utility) {
                        try? data.write(to: saveUrl)
                    }
                }

                return image
            } catch {
                return nil
            }
        }

        return nil
    }

    // Preload image into cache (for prefetching)
    func preloadImage(from url: URL) {
        Task {
            _ = await loadRemoteImage(from: url)
        }
    }

    // Clear in-memory image cache
    func clearCache() {
        memoryCache.removeAllObjects()
    }
}
