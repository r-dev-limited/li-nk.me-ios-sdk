# Changelog

All notable changes to the LinkMe iOS SDK.

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
