import SwiftUI

struct ContentView: View {
    var body: some View {
        EditorLayoutView()
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
