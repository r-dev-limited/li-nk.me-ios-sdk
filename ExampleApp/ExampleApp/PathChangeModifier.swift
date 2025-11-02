import SwiftUI

struct PathChangeModifier: ViewModifier {
    @ObservedObject var appState: AppState
    @State private var previousPath: String = ""
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                previousPath = appState.currentPath
            }
            .onChange(of: appState.currentPath) { newValue in
                // Navigation will be handled by NavigationLink or path changes
                if newValue != previousPath {
                    previousPath = newValue
                }
            }
    }
}

