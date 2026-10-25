# Changelog

All notable changes to the LinkMe iOS SDK.

## Unreleased

- Expose runtime-discoverable wrapper lifecycle protocol V1 with owner/generation guards, idempotent control replay and scoped read/listener frames. Native Flutter channel integration and coordinated release pins remain pending.
- Invalidate pending work when advertising consent changes; direct native lifecycle/identity changes withdraw wrapper ownership.

- Add a public total HTTP `requestTimeout`, active task cancellation and `dispose()`. App/identity changes invalidate queued delivery and reset app context; claims settle once despite timeout/cancellation races.
- Serialize listener/completion delivery, preserve subscription order, and guard reentrant lifecycle changes and scheduled main-thread browser, device-metadata and clipboard operations.
- Handle forced-web opening in the macOS core, suppressing app-route callbacks and completion payloads as on iOS. Wrapper release dependencies remain unchanged.

- Preserve optional `navigationAllowed` and suppress routing callbacks/browser launches when false. Accept campaign-only inferred receipts without exposing a CID or private route.

- Preserve additive claim ID, method, confidence, attribution status, payload contract version, and claim policy version in routing payloads.

## 0.2.16

- Adds an explicit 15-second deadline to SDK requests so offline or stalled transports cannot wait indefinitely.
- Adds URLProtocol-backed transport, HTTP failure, and timeout regression tests without changing the public API.

## 0.2.15

- Makes listener removal token-based and idempotent, gates device collection, and suppresses forced-web claim delivery after opening the browser.
- Supports `setUserId(nil)` to clear event identity and adds listener/configuration regression tests.
- Preserves `cid`/`duplicate` attribution fields while retaining the existing positional payload initializer order.

## 0.2.14

- Publishes `Package.swift` at the repository root so Swift Package Manager can resolve the SDK directly from the Git URL.
- Keeps the SDK source and tests in standard SwiftPM `Sources/` and `Tests/` directories.
- Declares macOS 10.15 support for Flutter's macOS SwiftPM integration.

## 0.2.13

- Tightens pasteboard deferred claim parsing to LinkMe hosts/token format only.
- Clears consumed pasteboard CIDs after successful deferred claim.

## 0.2.12

- Adds support for force-web redirect payloads (`forceRedirectWeb=true` + `webFallbackUrl`).
- Improved pasteboard claim reliability.

## 0.2.11

- Internal reliability improvements for link resolution.

## 0.2.9

- Improved handling of edge redirect scenarios.
- Better link lifecycle and maintenance behavior.

## 0.2.8

- General stability and bug fixes.

## 0.2.7

- Adds `isLinkMe` and `url` fields to payloads to distinguish LinkMe-managed links from basic universal links.

## 0.2.5

- Relaxes pasteboard parsing to accept branded LinkMe domains and structured `linkme:cid=...` tokens.

## 0.2.4

- SDK alignment release across all platforms.

## 0.2.3

- Internal improvements to deferred claim handling.

## 0.2.1

- Adds `debug` flag to config for verbose instrumentation.
- Fingerprint-based deferred claim improvements.

## 0.2.0

- Deferred deep linking support via pasteboard (deterministic) and fingerprint fallback (probabilistic).
- `setReady()` to control when queued URLs are processed.
- Analytics event tracking with `track()`.
- User ID association with `setUserId()`.
- Advertising consent toggle with `setAdvertisingConsent()`.

## 0.1.2

- Initial public release.
- Core deep linking: `configure`, `handle(userActivity:)`, `handle(url:)`, `getInitialLink`, `addListener`.
