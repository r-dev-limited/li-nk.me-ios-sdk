## LinkMe iOS SDK (Swift)

### Installation
- Swift Package Manager
  - In Xcode: File → Add Package Dependencies…
  - Enter this repository URL and add the package to your app target
  - Alternatively, in `Package.swift`:
```swift
.package(url: "<this-repository-url>", branch: "main")
```

### Quick start
```swift
import LinkMeKit

// Initialize once (e.g., in your App start)
LinkMe.shared.configure(config: .init(
  baseUrl: URL(string: "https://your-link-domain.tld")!,
  appId: "<APP_ID>",
  appKey: "<APP_KEY>",
  enablePasteboard: false
))

// Get the initial link and listen for subsequent ones
LinkMe.shared.getInitialLink { payload in /* route initial */ }
let unsubscribe = LinkMe.shared.addListener { payload in /* subsequent links */ }

// Optional deferred claim on first launch
LinkMe.shared.claimDeferredIfAvailable { payload in /* first launch fallback */ }

// Optional analytics
LinkMe.shared.track(event: "open")
```

### App delegate integration
```swift
@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    LinkMe.shared.handle(userActivity: userActivity)
  }
  func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    LinkMe.shared.handle(url: url)
  }
}
```

### Platform setup
- Associated Domains: add `applinks:<your-domain>` to target capabilities
- Ensure your domain serves a valid AASA file with your bundle/team IDs
- Optional: register a custom URL scheme in Info.plist (CFBundleURLTypes) if you use one

### Example app
- See `ExampleApp/` in this repository for a runnable SwiftUI example wired to the SDK

### Changelog
- See `CHANGELOG.md` (GitHub Releases also document changes)

### License
- Apache License 2.0
