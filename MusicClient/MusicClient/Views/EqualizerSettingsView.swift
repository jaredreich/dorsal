import SwiftUI

struct EqualizerSettingsView: View {
    @ObservedObject private var audioPlayer = AudioPlayerManager.shared

    var body: some View {
        List {
            Section {
                Toggle("settings.equalizer.enabled", isOn: $audioPlayer.isEqualizerEnabled)
            }

            Section {
                Picker("settings.equalizer.preset", selection: Binding(
                    get: { audioPlayer.selectedPreset },
                    set: { audioPlayer.applyPreset($0) }
                )) {
                    ForEach(EqualizerPreset.allPresets) { preset in
                        Text(preset.localizedName).tag(preset)
                    }
                }
            }

            Section {
                EqualizerBandsView(
                    gains: Binding(
                        get: { audioPlayer.equalizerGains },
                        set: { newGains in
                            for (i, gain) in newGains.enumerated() where gain != audioPlayer.equalizerGains[i] {
                                audioPlayer.setEqualizerBandGain(band: i, gain: gain)
                            }
                        }
                    ),
                    isEnabled: audioPlayer.selectedPreset == .custom
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                // .transaction { $0.animation = nil }

                Button("settings.equalizer.reset") {
                    audioPlayer.resetCustomEqualizer()
                }
                .foregroundColor(.red)
                .disabled(audioPlayer.selectedPreset != .custom)
            } header: {
                Text("settings.equalizer.bands")
            }
        }
        .navigationTitle("settings.equalizer.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct EqualizerBandsView: View {
    @Binding var gains: [Float]
    let isEnabled: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<10, id: \.self) { index in
                VStack(spacing: 4) {
                    Text(verbatim: gainLabel(gains[index]))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(height: 14)
                        .padding(.bottom, 8)

                    VerticalSlider(value: Binding(
                        get: { gains[index] },
                        set: { gains[index] = roundToInt($0) }
                    ), range: -12...12)
                    .frame(height: 180)
                    .disabled(!isEnabled)
                    .opacity(isEnabled ? 1.0 : 0.4)

                    Text(verbatim: EqualizerPreset.bandLabels[index])
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
    }

    private func gainLabel(_ gain: Float) -> String {
        let rounded = Int(gain.rounded())
        if rounded == 0 { return "0" }
        return String(format: "%+d", rounded)
    }

    private func roundToInt(_ value: Float) -> Float {
        let rounded = value.rounded()
        return rounded == 0 ? 0 : rounded
    }
}

private struct VerticalSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let span = range.upperBound - range.lowerBound
            let normalized = CGFloat((value - range.lowerBound) / span)
            let thumbY = height * (1 - normalized)
            let centerY = height * CGFloat(1 - (0 - range.lowerBound) / span)

            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 4)

                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 1)
                    .position(x: geometry.size.width / 2, y: centerY)

                let fillTop = min(thumbY, centerY)
                let fillHeight = abs(thumbY - centerY)
                if fillHeight > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: 4, height: fillHeight)
                        .position(x: geometry.size.width / 2, y: fillTop + fillHeight / 2)
                }

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: isDragging ? 20 : 16, height: isDragging ? 20 : 16)
                    .shadow(radius: 1)
                    .position(x: geometry.size.width / 2, y: thumbY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let fraction = 1 - Float(gesture.location.y / height)
                        let clamped = min(max(fraction, 0), 1)
                        value = range.lowerBound + clamped * span
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
    }
}

extension EqualizerPreset {
    var localizedName: LocalizedStringKey {
        switch id {
        case "flat": return "settings.equalizer.preset.flat"
        case "bass_boost": return "settings.equalizer.preset.bass_boost"
        case "treble_boost": return "settings.equalizer.preset.treble_boost"
        case "vocal": return "settings.equalizer.preset.vocal"
        case "rock": return "settings.equalizer.preset.rock"
        case "acoustic": return "settings.equalizer.preset.acoustic"
        case "custom": return "settings.equalizer.preset.custom"
        default: return LocalizedStringKey(name)
        }
    }
}
