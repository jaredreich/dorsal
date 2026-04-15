import SwiftUI

struct AlbumArtView: View {
    let imageUrl: String?
    let albumId: String
    let size: CGFloat

    @State private var loadedImage: UIImage?
    @State private var isLoading = false

    private let imageCache = ImageCacheManager.shared

    private var localImageUrl: URL? {
        let albumArtUrl = DownloadManager.shared.getAlbumArtUrl(for: albumId)
        return FileManager.default.fileExists(atPath: albumArtUrl.path) ? albumArtUrl : nil
    }

    var body: some View {
        Group {
            if let uiImage = loadedImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholderView
            }
        }
        .frame(width: size, height: size)
        .cornerRadius(8)
        .onAppear {
            if let cachedImage = imageCache.getCachedImage(localUrl: localImageUrl, remoteUrlString: imageUrl) {
                loadedImage = cachedImage
            }
        }
        .task(id: cacheKey) {
            await loadImageFromCache()
        }
    }

    private var cacheKey: String {
        if let localUrl = localImageUrl {
            return localUrl.absoluteString
        } else if let remoteUrl = imageUrl {
            return remoteUrl
        } else {
            return ""
        }
    }

    private var placeholderView: some View {
        Rectangle()
            .foregroundColor(.gray.opacity(0.3))
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.3))
                    .foregroundColor(.gray)
            )
    }

    private func loadImageFromCache() async {
        guard !cacheKey.isEmpty else {
            loadedImage = nil
            return
        }

        isLoading = true

        let image = await imageCache.loadImage(
            localUrl: localImageUrl,
            remoteUrlString: imageUrl,
            saveToUrl: DownloadManager.shared.getAlbumArtUrl(for: albumId)
        )

        loadedImage = image
        isLoading = false
    }
}
