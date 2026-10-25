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

**Swift Package Manager (recommended; iOS 14+; macOS 10.15+):**

1. In Xcode: **File > Add Packages...**
2. Enter `https://github.com/r-dev-limited/li-nk.me-ios-sdk`
3. Select `v0.2.16` or a later version tag and add `LinkMeKit` to your app target. The package manifest is at the repository root.

**CocoaPods (legacy):**

The `v0.2.16` source release is available directly from Git while its CocoaPods trunk spec is being published:

```ruby
pod 'LinkMeKit', :git => 'https://github.com/r-dev-limited/li-nk.me-ios-sdk.git', :tag => 'v0.2.16'
```

If your project must use the CocoaPods registry, remain on `LinkMeKit` `0.2.13` until the `0.2.16` spec appears on trunk.

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
      baseUrl: URL(string: "https://li-nk.me")!,
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
| `setUserId(_:)` | Associate a user ID; pass `nil` to clear it |
| `setAdvertisingConsent(_:)` | Toggle advertising identifier usage |
| `setReady()` | Signal readiness to process queued URLs |

## Example app

The `ExampleApp/` directory contains a runnable SwiftUI sample. Update `ExampleApp/Configuration/linkme.env` with your keys and run on a device or simulator.

## License

Apache-2.0

## Claim metadata (unreleased)

Updated Edge claims can include `claimId`, `claimMethod`, `matchConfidence`,
`attributionStatus`, `contractVersion`, and `claimPolicyVersion`. These optional
fields are preserved in the payload. Treat `fingerprint_exact` / `inferred` as
heuristic attribution, not a verified install or authenticated identity.
Replaying a CID returns its saved outcome; `duplicate` is a deprecated legacy
projection and must not suppress a new link navigation based on shared IP/UA.

Supply your app ID for deferred matching. New apps have fingerprint fallback
disabled; enable inferred attribution explicitly in app settings if appropriate.
Enabled matching requires a unique exact IP/UA candidate within 30 minutes.
Explicit CID and Play referrer claims use the deterministic 72-hour token window,
subject to link expiry and current app/link/domain policy.


Fingerprint matches return campaign/claim metadata with `navigationAllowed: false`.
They withhold the CID, link ID, path, custom data, query parameters and destination
URLs. The SDK suppresses app-routing callbacks and automatic browser launches for
these responses. Web callers can inspect returned metadata explicitly; native
routing APIs may return no link. A claim receipt is not a redeemable link token.
An independently supplied valid CID/referrer can still authorize navigation with
`navigationAllowed: true`; it retains the original claim receipt and attribution
classification rather than generating another claim.

## Tracking credentials and acceptance (unreleased Edge)

Configure an app ID and a key with `can_ingest` for client telemetry. In Portal,
select **Client analytics and link reading**; it cannot manage links, settings,
or keys, and cannot read private management/visitor diagnostics. A read-only key cannot ingest events. Both event routes require validated
credentials even when link resolution permits optional keys.

The existing `track` API uses the legacy `/api/app-events` route. Its return does
not prove delivery, durable webhook acknowledgement, or a verified conversion.
The SDK currently has no durable telemetry queue and does not promise event-ID
retry semantics. New Edge stores legacy events with app scope; an omitted event
ID receives a server ID, so calling `track` again creates another event. Optional
`userId` is a caller-provided pseudonym, not authenticated identity.

For explicit persistence receipts and safe HTTP retries, `/api/app-events/v1`
accepts a versioned envelope with a stable `eventId`, `occurredAt`, SDK/version,
platform, consent and structured properties. Reuse the same event ID and content
on retry; a successful receipt is 202, changed content is 409. The route requires
`can_ingest`, bounds the body to 32 KiB, and rate-limits by app. Claim events are
server-owned. This SDK has not yet adopted the versioned sender/queue contract.

## Request lifecycle (unreleased)

`LinkMe.Config` accepts `requestTimeout` in seconds. The default is 15 seconds for
the entire HTTP operation, including response-body reception. A positive finite
value up to 2147483.647 seconds overrides it; invalid values fall back to 15 to
preserve the nonthrowing configuration initializer. Deferred claims, explicit
CID/URL resolution and tracking use the same deadline/task owner.

`LinkMe.shared.cancelPendingRequests()` cancels active network tasks and invalidates
queued results/browser launches; subsequent requests remain usable. Reconfigure,
identity changes and `dispose()` also invalidate pending work. App reconfiguration
clears the saved payload, identity and attribution context. `dispose()` additionally
clears configuration, pending URLs and listeners. No automatic retry is added;
cancelling a caller cannot retract a mutation already accepted by Edge.

Listeners and payload completions run on the SDK's serial background delivery
queue. Browser opening, UIKit device metadata and clipboard access run on main with a current
lifecycle check. Listeners are called in subscription order, persist through
reconfigure and do not replay automatically. `getInitialLink` explicitly reads the
current saved payload. A reentrant lifecycle change stops later listeners and
returns no old payload to the pending completion. Listener removal is synchronous
and idempotent. A URL received before initial configuration is queued once.

A valid forced-web result opens the platform browser on iOS/macOS and returns no
app-routing payload; inferred metadata cannot launch a browser or reach routing
listeners. macOS opening now occurs in the core rather than requiring a wrapper.
Actual browser return/association loops, physical clipboard permissions, older OS
versions and published wrapper/core combinations still need qualification.


The local core also exposes lifecycle protocol V1 for wrappers that discover
support at runtime. Commands and payload frames carry an opaque owner and client
generation; control retries do not cancel newer work, and foreign/stale owners
cannot read payloads. Direct typed-core lifecycle/identity/changed advertising
consent calls withdraw wrapper ownership. Changed advertising consent also
invalidates pending work. This does not implement all collection controls.
Flutter public Dart integration with the native channel adapters and coordinated
published core dependencies remain pending; the current Flutter pins do not provide this protocol.
