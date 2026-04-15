import Foundation

struct Song: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let artistName: String
    let albumName: String
    let albumId: String
    let duration: TimeInterval?
    let trackNumber: Int?
    let discNumber: Int?
    let imageUrl: String?
}

extension TimeInterval {
    var formattedDuration: String {
        let minutes = Int(self) / 60
        let seconds = Int(self) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension Array where Element == Song {
    var totalDuration: TimeInterval {
        compactMap { $0.duration }.reduce(0, +)
    }

    var totalMinutes: Int {
        Int(totalDuration / 60)
    }

    func sortedByTrack() -> [Song] {
        self.sorted { song1, song2 in
            let disc1 = song1.discNumber ?? 1
            let disc2 = song2.discNumber ?? 1
            if disc1 != disc2 {
                return disc1 < disc2
            }
            return (song1.trackNumber ?? 0) < (song2.trackNumber ?? 0)
        }
    }
}
