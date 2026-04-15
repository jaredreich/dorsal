import Foundation

struct Album: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let artistName: String
    let year: Int?
    let imageUrl: String?
    let songCount: Int?
    let dateAdded: Date?
    let imageTag: String?

    init(id: String, name: String, artistName: String, year: Int? = nil, imageUrl: String? = nil, songCount: Int? = nil, dateAdded: Date? = nil, imageTag: String? = nil) {
        self.id = id
        self.name = name
        self.artistName = artistName
        self.year = year
        self.imageUrl = imageUrl
        self.songCount = songCount
        self.dateAdded = dateAdded
        self.imageTag = imageTag
    }

    // Standard sorting comparator: by artist name (case-insensitive), then by year (oldest to newest)
    static func standardSort(album1: Album, album2: Album) -> Bool {
        let artistComparison = album1.artistName.localizedStandardCompare(album2.artistName)
        if artistComparison != .orderedSame {
            return artistComparison == .orderedAscending
        }
        // Same artist, sort by year (oldest first)
        // Albums without year go to the end
        let year1 = album1.year ?? Int.max
        let year2 = album2.year ?? Int.max
        return year1 < year2
    }

    func hasMultipleDiscs(songs: [Song]) -> Bool {
        let discNumbers = Set(songs.compactMap { $0.discNumber })
        return discNumbers.count > 1
    }

    func groupedByDisc(songs: [Song]) -> [Int: [Song]] {
        Dictionary(grouping: songs) { $0.discNumber ?? 1 }
    }

    func sortedDiscNumbers(songs: [Song]) -> [Int] {
        Set(songs.compactMap { $0.discNumber ?? 1 }).sorted()
    }
}
