import SwiftUI

struct CircularDownloadProgress: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.appAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: progress)
        }
    }
}
