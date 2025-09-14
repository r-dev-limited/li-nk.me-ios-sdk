import SwiftUI
import LinkMeKit
import AppTrackingTransparency

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        let handled = LinkMe.shared.handle(userActivity: userActivity)
        if let url = userActivity.webpageURL {
            print("[LinkMe Example] continue userActivity URL=\(url.absoluteString) handled=\(handled)")
        }
        return handled
    }
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        let handled = LinkMe.shared.handle(url: url)
        print("[LinkMe Example] open url=\(url.absoluteString) handled=\(handled)")
        return handled
    }
}

@main
struct ExampleAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
