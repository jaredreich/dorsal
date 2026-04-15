import Foundation

struct AlbumMetadata: Codable {
    let album: Album
    let songs: [Song]
}
