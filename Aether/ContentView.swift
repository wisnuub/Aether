import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if !appState.isSetupComplete {
                SetupView()
            } else {
                LibraryView()
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: appState.isSetupComplete)
    }
}
