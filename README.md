# LinkMe iOS SDK

Deep linking, deferred deep linking, and attribution for iOS apps.

[![CocoaPods](https://img.shields.io/cocoapods/v/LinkMeKit)](https://cocoapods.org/pods/LinkMeKit)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

- [Main Site](https://li-nk.me)
- [Setup Guide](https://help.li-nk.me/hc/link-me/en/developer-setup/ios-setup-guide)
- [SDK Reference](https://help.li-nk.me/hc/link-me/en/sdks/ios-sdk-reference)
- [Help Center](https://help.li-nk.me/hc/link-me/en)

## Quick start

### 1. Prerequisites

- A LinkMe account with at least one app configured
- iOS bundle ID and Apple Team ID added in the LinkMe portal
- API keys (`appId` and `appKey`) from **App Settings > API Keys**

### 2. Install

**Swift Package Manager:**

1. In Xcode: **File > Add Packages...**
2. Enter `https://github.com/r-dev-limited/li-nk.me-ios-sdk`
3. Select the latest version tag and add `LinkMeKit` to your app target

**CocoaPods:**

```ruby
pod 'LinkMeKit', '~> 0.2.13'
```

### 3. Configure Universal Links

1. In Xcode, enable **Signing & Capabilities > Associated Domains** and add:

```
applinks:links.yourco.com
```

2. Add a custom URL scheme in `Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>yourapp</string>
    </array>
  </dict>
</array>
```

LinkMe hosts the AASA file automatically once your domain is connected.

### 4. Initialize the SDK

```swift
import LinkMeKit

@main
struct MyApp: App {
  init() {
    LinkMe.shared.configure(config: .init(
      appId: "your_app_id",
      appKey: "your_app_key",
      sendDeviceInfo: true,
      includeVendorId: true,
      includeAdvertisingId: false,
      debug: true
    ))
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
```

### 5. Handle links

```swift
struct ContentView: View {
  @State private var message = "Waiting for link..."

  var body: some View {
    Text(message)
      .onOpenURL { url in LinkMe.shared.handle(url: url) }
      .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
        LinkMe.shared.handle(userActivity: activity)
      }
      .task {
        // Cold-start link
        LinkMe.shared.getInitialLink { initial in
          if let initial {
            message = "Opened via \(initial.path)"
          } else {
            // Deferred deep link (first install)
            LinkMe.shared.claimDeferredIfAvailable { deferred in
              if let deferred {
                message = "Deferred: \(deferred.path)"
              }
            }
          }
        }

        // Live links while app is running
        let _ = LinkMe.shared.addListener { payload in
          message = "Link: \(payload.path)"
        }
      }
  }
}
```

## Deferred deep linking

The SDK supports two strategies for first-install attribution:

1. **Pasteboard** (deterministic) — reads a `cid` token written by the LinkMe Edge interstitial before the App Store redirect. Enable **Pasteboard for Deferred Links** in App Settings.
2. **Fingerprint** (probabilistic fallback) — calls `/api/deferred/claim` when pasteboard is unavailable.

Both are handled automatically by `claimDeferredIfAvailable()`.

## API reference

| Method | Description |
| --- | --- |
| `configure(config:)` | Initialize the singleton |
| `handle(userActivity:)` | Forward `NSUserActivity` for Universal Links |
| `handle(url:)` | Forward custom scheme URLs |
| `getInitialLink(completion:)` | Get the payload that opened the app |
| `addListener(_:)` | Subscribe to link events (returns unsubscribe closure) |
| `claimDeferredIfAvailable(completion:)` | Claim deferred deep link on first install |
| `track(event:properties:)` | Send analytics events |
| `setUserId(_:)` | Associate a user ID |
| `setAdvertisingConsent(_:)` | Toggle advertising identifier usage |
| `setReady()` | Signal readiness to process queued URLs |

## Example app

The `ExampleApp/` directory contains a runnable SwiftUI sample. Update `ExampleApp/Configuration/linkme.env` with your keys and run on a device or simulator.

## License

Apache-2.0
