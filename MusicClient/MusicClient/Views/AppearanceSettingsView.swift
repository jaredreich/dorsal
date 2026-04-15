import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var selectedColor: Color = ThemeManager.shared.accentColor

    var body: some View {
        List {
            Section {
                ColorPicker("settings.appearance.accent_color", selection: $selectedColor, supportsOpacity: false)
                    .onChange(of: selectedColor) { newColor in
                        themeManager.setAccentColor(newColor)
                    }

                Button("settings.appearance.reset_default") {
                    selectedColor = ThemeManager.defaultAccentColor
                    themeManager.setAccentColor(ThemeManager.defaultAccentColor)
                }
                .foregroundColor(.red)
            } header: {
                Text("settings.appearance.accent_color")
            } footer: {
                Text("settings.appearance.accent_color.footer")
            }
        }
        .navigationTitle("settings.appearance.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}
