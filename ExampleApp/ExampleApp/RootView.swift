import SwiftUI
import LinkMeKit

struct RootView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Group {
            if #available(iOS 16, *) {
                NavigationStack {
                    currentView
                        .navigationDestination(for: String.self) { path in
                            viewForPath(path)
                        }
                }
            } else {
                NavigationView {
                    currentView
                }
            }
        }
        .onOpenURL { url in
            print("[RootView] onOpenURL: \(url.absoluteString)")
            _ = LinkMe.shared.handle(url: url)
        }
        .modifier(PathChangeModifier(appState: appState))
    }
    
    @ViewBuilder
    private var currentView: some View {
        switch appState.currentPath {
        case "index", "home":
            HomeView()
        case "profile":
            ProfileView()
        case "settings":
            SettingsView()
        default:
            HomeView()
        }
    }
    
    @ViewBuilder
    private func viewForPath(_ path: String) -> some View {
        switch path {
        case "index", "home":
            HomeView()
        case "profile":
            ProfileView()
        case "settings":
            SettingsView()
        default:
            HomeView()
        }
    }
}

