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
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .onAppear {
                    initializeLinkMe()
                }
        }
    }
    
    private func initializeLinkMe() {
        print("[LinkMe Example] Initializing LinkMe SDK")
        
        let baseUrl = URL(string: "https://0jk2u2h9.li-nk.me")!
        let appId = "0jk2u2h9"
        let appKey = "ak_CgJwMBftYHC_7_WU8i-zIQb4a3OXZ4yqazp87iF2uus"
        
        LinkMe.shared.configure(config: .init(
            baseUrl: baseUrl,
            appId: appId,
            appKey: appKey,
            enablePasteboard: false,
            sendDeviceInfo: true,
            includeVendorId: true,
            includeAdvertisingId: false
        ))
        
        _ = LinkMe.shared.addListener { payload in
            DispatchQueue.main.async {
                appState.lastPayload = payload
                print("[LinkMe Example] Received payload: \(payload)")
                
                if let path = payload.path {
                    appState.navigateToPath(path)
                }
            }
        }
        
        if #available(iOS 14, *) {
            ATTrackingManager.requestTrackingAuthorization { status in
                DispatchQueue.main.async {
                    let granted = (status == .authorized)
                    LinkMe.shared.setAdvertisingConsent(granted)
                    appState.attStatus = status
                    print("[LinkMe Example] ATT status: \(status), granted: \(granted)")
                }
            }
        }
        
        LinkMe.shared.getInitialLink { payload in
            DispatchQueue.main.async {
                print("[LinkMe Example] Initial link: \(String(describing: payload))")
                if let p = payload {
                    appState.lastPayload = p
                    if let path = p.path {
                        appState.navigateToPath(path)
                    }
                } else {
                    LinkMe.shared.claimDeferredIfAvailable { deferredPayload in
                        DispatchQueue.main.async {
                            print("[LinkMe Example] Deferred link: \(String(describing: deferredPayload))")
                            if let p = deferredPayload {
                                appState.lastPayload = p
                                if let path = p.path {
                                    appState.navigateToPath(path)
                                }
                            }
                        }
                    }
                }
            }
        }
        
        LinkMe.shared.track(event: "open")
    }
}
