import SwiftUI
import Foundation

class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    static let defaultAccentColor = Color(red: 170 / 255, green: 92 / 255, blue: 195 / 255) // #AA5CC3

    @Published var accentColor: Color

    private init() {
        if let data = UserDefaults.standard.data(forKey: "accentColor"),
           let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) {
            accentColor = Color(uiColor: uiColor)
        } else {
            accentColor = ThemeManager.defaultAccentColor
        }
    }

    func setAccentColor(_ color: Color) {
        accentColor = color
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: UIColor(color), requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "accentColor")
        }
    }
}

extension Color {
    static var appAccent: Color {
        ThemeManager.shared.accentColor
    }
}
