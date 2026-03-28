# LinkMe iOS SDK

iOS SDK for LinkMe — deep linking and attribution.

- **Main Site**: [li-nk.me](https://li-nk.me)
- **Documentation**: [iOS Setup](https://li-nk.me/docs/developer/setup/ios)
- **Package**: [CocoaPods](https://cocoapods.org/pods/LinkMeKit)

## Installation

**Swift Package Manager:**
```
https://github.com/r-dev-limited/li-nk.me-ios-sdk
```

**CocoaPods:**
```ruby
pod 'LinkMeKit', '~> 0.2.9'
```

## Basic Usage

```swift
LinkMe.shared.configure(config: .init(
  appId: "your_app_id",
  appKey: "your_app_key",
  debug: true
))
```

## API

| Method | Description |
| --- | --- |
| `configure(config:)` | Initialize the singleton. |
| `handle(userActivity:)` | Forward `NSUserActivity` for Universal Links. |
| `handle(url:)` | Forward custom scheme URLs. |
| `getInitialLink(completion:)` | Get the payload that opened the app. |
| `addListener(_:)` | Subscribe to link events. Returns unsubscribe closure. |
| `claimDeferredIfAvailable(completion:)` | Pasteboard + fingerprint deferred claim. |
| `track(event:properties:)` | Send analytics events. |
| `setUserId(_:)` | Associate a user ID. |
| `setAdvertisingConsent(_:)` | Toggle advertising identifier usage. |
| `setReady()` | Signal readiness to process queued URLs. |

For full documentation, guides, and API reference, please visit our [Help Center](https://li-nk.me/docs/help).

## License

Apache-2.0
