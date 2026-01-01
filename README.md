# LinkMe iOS SDK

iOS SDK for LinkMe — deep linking and attribution.

- **Main Site**: [li-nk.me](https://li-nk.me)
- **Documentation**: [iOS Setup](https://li-nk.me/docs/developer/setup/ios)
- **Package**: [CocoaPods](https://cocoapods.org/pods/LinkMeKit)

## Installation

```ruby
pod 'LinkMeKit', '~> 0.2.7'
```

## Basic Usage

```swift
LinkMe.shared.configure(config: .init(
  appId: "your_app_id",
  appKey: "your_app_key",
  debug: true
))
```

For full documentation, guides, and API reference, please visit our [Help Center](https://li-nk.me/docs/help).

## License

Apache-2.0
