import SwiftUI

enum FilterOption: String, CaseIterable {
    case library = "Library"
    case latestAdded = "Latest Added"
    case recentlyPlayed = "Recently Played"
    case offline = "Offline"

    var localizedName: LocalizedStringKey {
        switch self {
        case .library: return "filter.library"
        case .latestAdded: return "filter.latest_added"
        case .recentlyPlayed: return "filter.recently_played"
        case .offline: return "filter.offline"
        }
    }

    var localizedString: String {
        switch self {
        case .library: return String(localized: "filter.library")
        case .latestAdded: return String(localized: "filter.latest_added")
        case .recentlyPlayed: return String(localized: "filter.recently_played")
        case .offline: return String(localized: "filter.offline")
        }
    }

    var icon: String {
        switch self {
        case .library:
            return "music.note.list"
        case .latestAdded:
            // NOTE: device-specific logic
            if #available(iOS 18.0, *) {
                return "square.and.arrow.down.badge.clock"
            }
            return "text.line.first.and.arrowtriangle.forward"
        case .recentlyPlayed:
            // NOTE: device-specific logic
            if #available(iOS 18.0, *) {
                return "clock.arrow.trianglehead.counterclockwise.rotate.90"
            }
            return "clock"
        case .offline:
            return "arrow.down.circle"
        }
    }
}
