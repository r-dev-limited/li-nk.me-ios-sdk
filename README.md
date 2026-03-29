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
pod 'LinkMeKit', '~> 0.2.12'
```

## Basic Usage

```swift
LinkMe.shared.configure(config: .init(
  appId: "your_app_id",
  appKey: "your_app_key",
  debug: true
))
```

## Manual deep-link setup mapping

Use this config shape for your app setup values:

```json
{
  "hosts": ["links.yourco.com"],
  "associatedDomains": ["links.yourco.com"],
  "schemes": ["yourapp"]
}
```

Required: this is not optional. Without Associated Domains + URL scheme setup, LinkMe deep links will not route into your iOS app.

What each field does and why it must be set:

- `hosts`: your HTTPS deep-link domain(s). iOS uses this domain for universal links.
- `associatedDomains`: domain allowlist for iOS universal links. Must match your entitlements.
- `schemes`: fallback custom URL scheme(s) for scheme-based opens.

If these values are missing or mismatched, links open in Safari or fail to route into the app.

configure iOS manually as:

- `hosts` / `associatedDomains` -> Associated Domains capability:

```text
applinks:links.yourco.com
```

- `schemes` -> `Info.plist` URL types (`CFBundleURLSchemes`):

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
