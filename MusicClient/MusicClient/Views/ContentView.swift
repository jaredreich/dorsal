import SwiftUI

struct ContentView: View {
    @EnvironmentObject var jellyfinService: JellyfinService

    var body: some View {
        Group {
            if jellyfinService.authState.isAuthenticated {
                MainTabView()
            } else {
                ServerSetupView()
            }
        }
    }
}
