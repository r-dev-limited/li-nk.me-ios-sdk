import SwiftUI
import LinkMeKit
import AppTrackingTransparency

class AppState: ObservableObject {
    @Published var lastPayload: LinkPayload?
    @Published var currentPath: String = "index"
    @Published var attStatus: ATTrackingManager.AuthorizationStatus = .notDetermined
    
    func navigateToPath(_ path: String) {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        currentPath = cleanPath.isEmpty ? "index" : cleanPath
        print("[AppState] Navigating to path: \(currentPath)")
    }
}

