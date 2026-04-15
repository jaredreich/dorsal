import Foundation

struct EqualizerPreset: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let gains: [Float]

    static let bandFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    static let bandLabels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    static let custom = EqualizerPreset(
        id: "custom",
        name: "Custom",
        gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    )

    static let flat = EqualizerPreset(
        id: "flat",
        name: "Flat",
        gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    )

    static let bassBoost = EqualizerPreset(
        id: "bass_boost",
        name: "Bass Boost",
        gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
    )

    static let trebleBoost = EqualizerPreset(
        id: "treble_boost",
        name: "Treble Boost",
        gains: [0, 0, 0, 0, 0, 0, 2, 4, 5, 6]
    )

    static let vocal = EqualizerPreset(
        id: "vocal",
        name: "Vocal",
        gains: [-2, -1, 0, 3, 4, 4, 3, 0, -1, -2]
    )

    static let rock = EqualizerPreset(
        id: "rock",
        name: "Rock",
        gains: [4, 3, 1, -1, -2, -1, 1, 3, 4, 4]
    )

    static let acoustic = EqualizerPreset(
        id: "acoustic",
        name: "Acoustic",
        gains: [3, 3, 2, 0, 1, 1, 2, 3, 2, 1]
    )

    static let allPresets: [EqualizerPreset] = [custom, flat, bassBoost, trebleBoost, vocal, rock, acoustic]
}
