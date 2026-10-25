import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif
#if canImport(AppTrackingTransparency)
  import AppTrackingTransparency
#endif
#if canImport(AdSupport)
  import AdSupport
#endif

public struct LinkPayload: Codable, Sendable {
  public let linkId: String?
  public let path: String?
  public let params: [String: String]?
  public let utm: [String: String]?
  public let custom: [String: String]?
  public let url: String?
  public let isLinkMe: Bool?
  public let forceRedirectWeb: Bool?
  public let webFallbackUrl: String?
  /// Deferred attribution identifier returned by the Edge API.
  public let cid: String?
  /// Legacy duplicate classification; retries preserve the original claim outcome.
  public let duplicate: Bool?
  public let claimId: String?
  public let claimMethod: String?
  public let matchConfidence: String?
  public let attributionStatus: String?
  public let contractVersion: Int?
  public let claimPolicyVersion: Int?
  public let navigationAllowed: Bool?


  public init(
    linkId: String? = nil,
    path: String? = nil,
    params: [String: String]? = nil,
    utm: [String: String]? = nil,
    custom: [String: String]? = nil,
    url: String? = nil,
    isLinkMe: Bool? = nil,
    forceRedirectWeb: Bool? = nil,
    webFallbackUrl: String? = nil,
    cid: String? = nil,
    duplicate: Bool? = nil,
    claimId: String? = nil,
    claimMethod: String? = nil,
    matchConfidence: String? = nil,
    attributionStatus: String? = nil,
    contractVersion: Int? = nil,
    claimPolicyVersion: Int? = nil,
    navigationAllowed: Bool? = nil
  ) {
    self.linkId = linkId
    self.path = path
    self.params = params
    self.utm = utm
    self.custom = custom
    self.url = url
    self.isLinkMe = isLinkMe
    self.forceRedirectWeb = forceRedirectWeb
    self.webFallbackUrl = webFallbackUrl
    self.cid = cid
    self.duplicate = duplicate
    self.claimId = claimId
    self.claimMethod = claimMethod
    self.matchConfidence = matchConfidence
    self.attributionStatus = attributionStatus
    self.contractVersion = contractVersion
    self.claimPolicyVersion = claimPolicyVersion
    self.navigationAllowed = navigationAllowed
  }
}

public final class LinkMe: NSObject, @unchecked Sendable {
  public static let shared = LinkMe()

  /// The transport is injectable inside the module so native tests can exercise
  /// request and timeout behavior without relying on a live Edge service.
  /// Public consumers continue to use the shared URLSession by default.
  private let transport: RequestScope
  private let defaultRequestTimeout: TimeInterval
  private let openExternalURL: @MainActor (URL) -> Void
  private let pasteboardTokenProvider: (() -> String?)?

  internal init(
    urlSession: URLSession = .shared,
    requestTimeout: TimeInterval = 15,
    makeTask: RequestTaskFactory? = nil,
    openExternalURL: (@MainActor (URL) -> Void)? = nil,
    deliveryQueue: DispatchQueue = DispatchQueue(label: "me.link.linkmekit"),
    pasteboardTokenProvider: (() -> String?)? = nil
  ) {
    self.transport = RequestScope(urlSession: urlSession, makeTask: makeTask)
    self.queue = deliveryQueue
    self.pasteboardTokenProvider = pasteboardTokenProvider
    self.defaultRequestTimeout = requestTimeout
    self.openExternalURL = openExternalURL ?? { target in
      #if canImport(UIKit)
        UIApplication.shared.open(target, options: [:], completionHandler: nil)
      #elseif canImport(AppKit)
        NSWorkspace.shared.open(target)
      #endif
    }
    super.init()
  }

  public struct Config: Sendable {
    public let baseUrl: URL
    public let appId: String?
    public let appKey: String?
    /// @deprecated Pasteboard is now controlled from the Portal (App Settings → iOS).
    /// The SDK automatically checks pasteboard in claimDeferredIfAvailable(). This parameter is ignored.
    @available(*, deprecated, message: "Pasteboard is now controlled from the Portal. This parameter is ignored.")
    public let enablePasteboard: Bool
    public let sendDeviceInfo: Bool
    public let includeVendorId: Bool
    public let includeAdvertisingId: Bool
    public let debug: Bool
    /// Total HTTP deadline in seconds. Nil uses the 15-second default.
    public let requestTimeout: TimeInterval?
    public init(
      baseUrl: URL,
      appId: String? = nil,
      appKey: String? = nil,
      enablePasteboard: Bool = false,
      sendDeviceInfo: Bool = true,
      includeVendorId: Bool = true,
      includeAdvertisingId: Bool = false,
      debug: Bool = false,
      requestTimeout: TimeInterval? = nil
    ) {
      self.baseUrl = baseUrl
      self.appId = appId
      self.appKey = appKey
      self.enablePasteboard = enablePasteboard
      self.sendDeviceInfo = sendDeviceInfo
      self.includeVendorId = includeVendorId
      self.includeAdvertisingId = includeAdvertisingId
      self.debug = debug
      // Keep the existing nonthrowing configuration initializer compatible.
      if let requestTimeout {
        self.requestTimeout = requestTimeout.isFinite && requestTimeout > 0 && requestTimeout <= 2_147_483.647 ? requestTimeout : 15
      } else {
        self.requestTimeout = nil
      }
    }
  }

  private var config: Config?
  private var userId: String?
  private var lastPayload: LinkPayload?
  private var listeners: [UUID: (LinkPayload) -> Void] = [:]
  private var listenerOrder: [UUID] = []
  private let stateLock = NSRecursiveLock()
  private var generation: UInt64 = 0
  private var lifecycleOwner: String?
  private var lifecycleClientGeneration = 0
  private var lifecycleKnownGenerations: [String: Int] = [:]
  private var lifecycleOwnerOrder: [String] = []
  private var lifecycleLastCommand: (owner: String, generation: Int, signature: Data)?
  private var lifecycleSubscriptions: [String: () -> Void] = [:]
  private var pendingURLs: [URL] = []
  private let queue: DispatchQueue
  private var advertisingConsentEnabled: Bool = false
  private var isReady: Bool = false
  private var debugEnabled: Bool { config?.debug ?? false }
  private var platformName: String {
    #if os(macOS)
      return "macos"
    #else
      return "ios"
    #endif
  }
  private static let utmKeys: Set<String> = [
    "utm_source",
    "utm_medium",
    "utm_campaign",
    "utm_term",
    "utm_content",
    "utm_id",
    "utm_source_platform",
    "utm_creative_format",
    "utm_marketing_tactic",
    "tags",
  ]

  private func debugLog(_ message: String, extra: [String: Any?]? = nil) {
    guard debugEnabled else { return }
    if let extra, !extra.isEmpty {
      print("[LinkMeKit] \(message) \(extra)")
    } else {
      print("[LinkMeKit] \(message)")
    }
  }

  /// Mutable SDK state is protected by a recursive lock. Delivery runs on the
  /// SDK serial queue; handlers may synchronously reconfigure/remove listeners.
  private func withState<T>(_ operation: () -> T) -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return operation()
  }

  private func isCurrent(_ expected: UInt64) -> Bool {
    generation == expected && config != nil && isReady
  }

  private func invalidateCurrentWork() {
    generation &+= 1
    transport.cancelAll()
  }

  public func cancelPendingRequests() {
    withState { invalidateCurrentWork(); resetLifecycleOwner() }
  }

  public func dispose() {
    withState {
      invalidateCurrentWork()
      config = nil
      isReady = false
      lastPayload = nil
      userId = nil
      advertisingConsentEnabled = false
      pendingURLs.removeAll()
      listeners.removeAll()
      listenerOrder.removeAll()
      lifecycleSubscriptions.removeAll()
      resetLifecycleOwner()
    }
  }

  public func configure(config: Config) {
    withState {
      let hadConfiguration = self.config != nil
      invalidateCurrentWork()
      resetLifecycleOwner()
      if hadConfiguration { pendingURLs.removeAll() }
      self.config = config
      self.lastPayload = nil
      self.userId = nil
      self.advertisingConsentEnabled = config.includeAdvertisingId
      self.isReady = true
      let expected = generation
      queue.async { [weak self] in
        guard let self else { return }
        self.withState {
          guard self.isCurrent(expected) else { return }
          self.drainPending()
          #if canImport(UIKit)
            if config.enablePasteboard { self.tryReadPasteboardToken() }
          #endif
        }
      }
    }
  }

  public func getInitialLink(completion: @escaping (LinkPayload?) -> Void) {
    let callback = CallbackBox(completion)
    withState {
      let expected = generation
      queue.async { [weak self] in
        guard let self else { callback.call(nil); return }
        self.withState { callback.call(self.isCurrent(expected) ? self.lastPayload : nil) }
      }
    }
  }

  @discardableResult
  public func addListener(_ handler: @escaping (LinkPayload) -> Void) -> () -> Void {
    let token = UUID()
    withState {
      listeners[token] = handler
      listenerOrder.append(token)
    }
    return { [weak self] in
      self?.withState {
        self?.listeners.removeValue(forKey: token)
        self?.listenerOrder.removeAll { $0 == token }
      }
    }
  }

  // For wiring tests only; uses the same guarded delivery as network payloads.
  public func _debugEmit(_ payload: LinkPayload) {
    withState {
      let expected = generation
      queue.async { [weak self] in
        self?.withState { self?.emit(payload: payload, generation: expected) }
      }
    }
  }

  // MARK: - Public link handlers
  #if canImport(UIKit)
    // Non-keyword API for forwarding Universal Links
    @discardableResult
    public func handle(userActivity: NSUserActivity) -> Bool {
      guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
        let url = userActivity.webpageURL
      else { return false }
      handleIncoming(url: url)
      return true
    }
  #endif

  /// Forward a URL opened by the host application. Available on every
  /// supported platform; platform-specific app delegates decide how to
  /// receive the URL.
  @discardableResult
  public func handle(url: URL) -> Bool {
    handleIncoming(url: url)
    return true
  }

  // First release: no deprecated aliases.

  public func claimDeferredIfAvailable(completion: @escaping (LinkPayload?) -> Void) {
    let callback = CallbackBox(completion)
    withState {
      let expected = generation
      #if canImport(UIKit)
        // UIKit clipboard access belongs on main, with a lifecycle check at
        // the point of the read. No stale configuration may trigger the read.
        DispatchQueue.main.async { [weak self] in
          guard let self else { callback.call(nil); return }
          self.withState {
            guard self.isCurrent(expected) else { self.complete(callback, payload: nil); return }
            let cid = self.pasteboardTokenProvider.map { $0() } ?? self.readPasteboardCid()
            if let cid {
              self.resolveCidWithCompletion(cid, clearPasteboard: true, completion: callback.call)
            } else {
              self.claimViaFingerprint(completion: callback.call)
            }
          }
        }
      #else
        queue.async { [weak self] in
          guard let self else { callback.call(nil); return }
          self.withState {
            guard self.isCurrent(expected) else { callback.call(nil); return }
            self.claimViaFingerprint(completion: callback.call)
          }
        }
      #endif
    }
  }

  private func complete(_ callback: CallbackBox<LinkPayload?>, payload: LinkPayload?) {
    queue.async { callback.call(payload) }
  }

  private func perform(_ request: URLRequest, generation expected: UInt64,
                       completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
    let callback = CallbackBox<(Data?, URLResponse?, Error?)> { result in
      completion(result.0, result.1, result.2)
    }
    let deliveryQueue = queue
    transport.start(request) { [weak self] data, response, error in
      deliveryQueue.async { [weak self] in
        guard let self else { callback.call((nil, nil, URLError(.cancelled))); return }
        self.withState {
          guard self.isCurrent(expected) else {
            callback.call((nil, nil, URLError(.cancelled)))
            return
          }
          callback.call((data, response, error))
        }
      }
    }
  }

  private func requestPayload(_ request: URLRequest, cid: String? = nil,
                              fallbackURL: URL? = nil, clearPasteboard: Bool = false,
                              completion: @escaping (LinkPayload?) -> Void) {
    let expected = generation
    let callback = CallbackBox(completion)
    perform(request, generation: expected) { [weak self] data, response, error in
      guard let self, error == nil, let http = response as? HTTPURLResponse else {
        callback.call(nil)
        return
      }
      var payload: LinkPayload?
      if (200..<300).contains(http.statusCode), let data {
        payload = self.decodePayload(data).map { self.annotatePayload($0, isLinkMe: true, cid: cid) }
      } else if let fallbackURL, let data, let body = String(data: data, encoding: .utf8), self.isDomainNotFound(body) {
        payload = self.buildBasicUniversalPayload(url: fallbackURL)
      }
      guard let payload, self.isCurrent(expected) else { callback.call(nil); return }
      #if canImport(UIKit)
        if clearPasteboard, let cid, payload.navigationAllowed != false {
          DispatchQueue.main.async { [weak self] in
            self?.withState {
              guard let self, self.isCurrent(expected) else { return }
              self.clearPasteboardCidIfPresent(cid)
            }
          }
        }
      #endif
      if self.handleForcedWebRedirect(payload, generation: expected) { callback.call(nil); return }
      self.emit(payload: payload, generation: expected)
      callback.call(self.isCurrent(expected) ? payload : nil)
    }
  }

  private func claimViaFingerprint(completion: @escaping (LinkPayload?) -> Void) {
    guard let cfg = config else { completion(nil); return }
    var request = URLRequest(url: cfg.baseUrl.appendingPathComponent("api/deferred/claim"))
    request.timeoutInterval = cfg.requestTimeout ?? defaultRequestTimeout
    request.httpMethod = "POST"
    setHeaders(on: &request)
    var body: [String: Any] = ["bundleId": Bundle.main.bundleIdentifier ?? "", "platform": platformName]
    if cfg.sendDeviceInfo, let device = buildDevicePayload() { body["device"] = device }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    requestPayload(request, completion: completion)
  }

  private func resolveCidWithCompletion(_ cid: String, clearPasteboard: Bool = false,
                                        completion: @escaping (LinkPayload?) -> Void) {
    guard let cfg = config else { completion(nil); return }
    var components = URLComponents(url: cfg.baseUrl.appendingPathComponent("api/deeplink"), resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "cid", value: cid)]
    guard let url = components.url else { completion(nil); return }
    var request = URLRequest(url: url)
    request.timeoutInterval = cfg.requestTimeout ?? defaultRequestTimeout
    setHeaders(on: &request)
    if cfg.sendDeviceInfo, let device = buildDevicePayload(),
       let data = try? JSONSerialization.data(withJSONObject: device), let json = String(data: data, encoding: .utf8) {
      request.setValue(json, forHTTPHeaderField: "x-linkme-device")
    }
    requestPayload(request, cid: cid, clearPasteboard: clearPasteboard, completion: completion)
  }

  public func setUserId(_ id: String?) {
    withState {
      if userId != id { invalidateCurrentWork(); resetLifecycleOwner() }
      userId = id
    }
  }

  public func setAdvertisingConsent(_ granted: Bool) {
    withState {
      if advertisingConsentEnabled != granted { invalidateCurrentWork(); resetLifecycleOwner() }
      advertisingConsentEnabled = granted
    }
  }

  public func track(event: String, props: [String: Any]? = nil) {
    withState {
      guard let cfg = config, isReady, !event.isEmpty else { return }
      let expected = generation
      var request = URLRequest(url: cfg.baseUrl.appendingPathComponent("api/app-events"))
      request.timeoutInterval = cfg.requestTimeout ?? defaultRequestTimeout
      request.httpMethod = "POST"
      setHeaders(on: &request)
      var body: [String: Any] = ["type": event, "platform": platformName, "timestamp": Int(Date().timeIntervalSince1970)]
      if let cid = lastPayload?.cid { body["cid"] = cid }
      if let linkId = lastPayload?.linkId { body["linkId"] = linkId }
      if let userId { body["userId"] = userId }
      if let props, let data = try? JSONSerialization.data(withJSONObject: props), let detail = String(data: data, encoding: .utf8) {
        body["detail"] = detail
      }
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      let preparedRequest = request
      queue.async { [weak self] in
        self?.withState {
          guard let self, self.isCurrent(expected) else { return }
          self.perform(preparedRequest, generation: expected) { _, _, _ in }
        }
      }
    }
  }

  private func handleIncoming(url: URL) {
    withState {
      guard config != nil, isReady else { pendingURLs.append(url); return }
      let expected = generation
      queue.async { [weak self] in
        self?.withState {
          guard let self, self.isCurrent(expected) else { return }
          self.processIncoming(url)
        }
      }
    }
  }

  private func processIncoming(_ url: URL) {
    #if canImport(UIKit)
      let expected = generation
      DispatchQueue.main.async { [weak self] in
        self?.withState {
          guard let self, self.isCurrent(expected) else { return }
          self.resolveIncoming(url)
        }
      }
    #else
      resolveIncoming(url)
    #endif
  }

  private func resolveIncoming(_ url: URL) {
    if let cid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cid" })?.value {
      resolveCid(cid)
    } else if url.scheme == "http" || url.scheme == "https" {
      resolveUniversalLink(url)
    }
  }

  private func drainPending() {
    guard config != nil, isReady else { return }
    let urls = pendingURLs
    pendingURLs.removeAll()
    for url in urls { processIncoming(url) }
  }

  public func setReady() {
    withState {
      isReady = true
      drainPending()
    }
  }

  private func resolveCid(_ cid: String) {
    resolveCidWithCompletion(cid) { _ in }
  }

  private func resolveUniversalLink(_ url: URL) {
    guard let cfg = config else { return }
    var request = URLRequest(url: cfg.baseUrl.appendingPathComponent("api/deeplink/resolve-url"))
    request.timeoutInterval = cfg.requestTimeout ?? defaultRequestTimeout
    request.httpMethod = "POST"
    setHeaders(on: &request)
    var body: [String: Any] = ["url": url.absoluteString]
    if cfg.sendDeviceInfo, let device = buildDevicePayload() { body["device"] = device }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    requestPayload(request, fallbackURL: url) { _ in }
  }

  deinit { transport.cancelAll() }

  // Build device payload with consent-aware identifiers.
  private func buildDevicePayload() -> [String: Any]? {
    guard let cfg = config else { return nil }
    var dev: [String: Any] = [:]
    dev["platform"] = platformName
    dev["bundleId"] = Bundle.main.bundleIdentifier ?? ""
    if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
      dev["appVersion"] = v
    }
    if let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String { dev["buildNumber"] = b }
    #if canImport(UIKit)
      let device = MainActor.assumeIsolated { (UIDevice.current.systemVersion, UIDevice.current.model) }
      dev["osVersion"] = device.0
      dev["deviceModel"] = device.1
    #endif
    dev["locale"] = Locale.current.identifier
    dev["timezone"] = TimeZone.current.identifier
    var consent: [String: Any] = [:]
    if cfg.includeVendorId {
      consent["vendor"] = true
      #if canImport(UIKit)
        if let idfv = MainActor.assumeIsolated({ UIDevice.current.identifierForVendor?.uuidString }) {
          dev["id_type"] = "idfv"
          dev["device_id"] = idfv
        }
      #endif
    }
    // We do not request ATT here; integrator should enable this flag only after user consent.
    if advertisingConsentEnabled {
      consent["advertising"] = true
      #if canImport(AdSupport) && !os(macOS)
        #if canImport(AppTrackingTransparency)
          if #available(iOS 14, *) {
            #if !os(macOS)
            if ATTrackingManager.trackingAuthorizationStatus == .authorized {
              let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
              if idfa != "00000000-0000-0000-0000-000000000000" {
                dev["id_type"] = "idfa"
                dev["device_id"] = idfa
              }
            }
            #endif
          } else {
            #if !os(macOS)
            if ASIdentifierManager.shared().isAdvertisingTrackingEnabled {
              let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
              if idfa != "00000000-0000-0000-0000-000000000000" {
                dev["id_type"] = "idfa"
                dev["device_id"] = idfa
              }
            }
            #endif
          }
        #else
          #if !os(macOS) && !targetEnvironment(macCatalyst)
          if #available(iOS 6, *) {
            if ASIdentifierManager.shared().isAdvertisingTrackingEnabled {
              let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
              if idfa != "00000000-0000-0000-0000-000000000000" {
                dev["id_type"] = "idfa"
                dev["device_id"] = idfa
              }
            }
          }
          #endif
        #endif
      #endif
    }
    dev["consent"] = consent
    return dev
  }

  private func setHeaders(on req: inout URLRequest) {
    if let appId = config?.appId { req.setValue(appId, forHTTPHeaderField: "x-app-id") }
    if let appKey = config?.appKey { req.setValue(appKey, forHTTPHeaderField: "x-api-key") }
    req.setValue("application/json", forHTTPHeaderField: "Accept")
  }

  private func emit(payload: LinkPayload, generation expected: UInt64) {
    guard isCurrent(expected), payload.navigationAllowed != false else { return }
    lastPayload = payload
    for token in listenerOrder {
      guard isCurrent(expected) else { break }
      listeners[token]?(payload)
    }
  }

  private func annotatePayload(_ payload: LinkPayload, isLinkMe: Bool? = nil, url: String? = nil, cid: String? = nil) -> LinkPayload {
    return LinkPayload(
      linkId: payload.linkId,
      path: payload.path,
      params: payload.params,
      utm: payload.utm,
      custom: payload.custom,
      url: payload.url ?? url,
      isLinkMe: payload.isLinkMe ?? isLinkMe,
      forceRedirectWeb: payload.forceRedirectWeb,
      webFallbackUrl: payload.webFallbackUrl,
      cid: payload.cid ?? cid,
      duplicate: payload.duplicate,
      claimId: payload.claimId,
      claimMethod: payload.claimMethod,
      matchConfidence: payload.matchConfidence,
      attributionStatus: payload.attributionStatus,
      contractVersion: payload.contractVersion,
      claimPolicyVersion: payload.claimPolicyVersion,
      navigationAllowed: payload.navigationAllowed
    )
  }

  private func decodePayload(_ data: Data) -> LinkPayload? {
    guard let payload = try? JSONDecoder().decode(LinkPayload.self, from: data) else { return nil }
    let hasField = payload.cid != nil || payload.linkId != nil || payload.path != nil || payload.params != nil ||
      payload.utm != nil || payload.custom != nil || payload.url != nil ||
      payload.isLinkMe != nil || payload.duplicate != nil || payload.forceRedirectWeb != nil || payload.webFallbackUrl != nil || (payload.navigationAllowed == false && payload.claimId?.isEmpty == false)
    return hasField ? payload : nil
  }

  private func buildBasicUniversalPayload(url: URL) -> LinkPayload? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let (params, utm) = splitQueryItems(components.queryItems)
    return LinkPayload(
      path: url.path.isEmpty ? "/" : url.path,
      params: params,
      utm: utm,
      url: url.absoluteString,
      isLinkMe: false,
      forceRedirectWeb: nil,
      webFallbackUrl: nil
    )
  }

  private func handleForcedWebRedirect(_ payload: LinkPayload, generation expected: UInt64) -> Bool {
    if payload.navigationAllowed == false { return true }
    guard payload.forceRedirectWeb == true else { return false }
    guard let raw = payload.webFallbackUrl, !raw.isEmpty, let target = URL(string: raw) else { return false }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.withState {
        guard self.isCurrent(expected) else { return }
        self.openExternalURL(target)
      }
    }
    return true
  }

  private func splitQueryItems(_ items: [URLQueryItem]?) -> ([String: String]?, [String: String]?) {
    guard let items, !items.isEmpty else { return (nil, nil) }
    var params: [String: String] = [:]
    var utm: [String: String] = [:]
    for item in items {
      guard let value = item.value else { continue }
      if LinkMe.utmKeys.contains(item.name) {
        utm[item.name] = value
      } else {
        params[item.name] = value
      }
    }
    return (params.isEmpty ? nil : params, utm.isEmpty ? nil : utm)
  }

  private func isDomainNotFound(_ body: String) -> Bool {
    guard let data = body.data(using: .utf8) else { return false }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    return (json["error"] as? String) == "domain_not_found"
  }

  #if canImport(UIKit)
    private func tryReadPasteboardToken() {
      let expected = generation
      DispatchQueue.main.async { [weak self] in
        self?.withState {
          guard let self, self.isCurrent(expected), let cid = self.readPasteboardCid() else { return }
          self.resolveCid(cid)
        }
      }
    }
    
    /// Reads a LinkMe cid from pasteboard.
    ///
    /// Accepts:
    /// - `linkme:cid=<hex>`
    /// - Any URL containing `?cid=<hex>` only when host is `li-nk.me`,
    ///   a `*.li-nk.me` subdomain, or the configured `baseUrl` host.
    private func readPasteboardCid() -> String? {
      guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty
      else { return nil }

      func isValidCid(_ cid: String) -> Bool {
        let re = try? NSRegularExpression(pattern: "^[a-fA-F0-9]{8,64}$")
        let range = NSRange(location: 0, length: cid.utf16.count)
        return re?.firstMatch(in: cid, options: [], range: range) != nil
      }

      if let m = raw.range(of: #"(^|\s)linkme:cid=([a-fA-F0-9]{8,64})(\s|$)"#, options: .regularExpression) {
        let token = String(raw[m])
        if let cidRange = token.range(of: #"[a-fA-F0-9]{8,64}"#, options: .regularExpression) {
          let cid = String(token[cidRange])
          return isValidCid(cid) ? cid : nil
        }
      }

      let urlCandidate: String = {
        if let m = raw.range(of: #"https?://\S+"#, options: .regularExpression) {
          return String(raw[m])
        }
        return raw
      }()

      if let url = URL(string: urlCandidate),
        let cid = URLComponents(url: url, resolvingAgainstBaseURL: false)?
          .queryItems?
          .first(where: { $0.name == "cid" })?
          .value,
        isValidCid(cid)
      {
        let host = (url.host ?? "").lowercased()
        guard isLikelyLinkMeHost(host) else {
          debugLog("Ignoring pasteboard cid from non-LinkMe host", extra: ["host": host])
          return nil
        }
        return cid
      }

      return nil
    }

    private func isLikelyLinkMeHost(_ host: String) -> Bool {
      guard !host.isEmpty else { return false }
      if host == "li-nk.me" || host.hasSuffix(".li-nk.me") {
        return true
      }
      if let configuredHost = config?.baseUrl.host?.lowercased(), !configuredHost.isEmpty {
        return host == configuredHost
      }
      return false
    }

    private func clearPasteboardCidIfPresent(_ cid: String) {
      let pasteboard = UIPasteboard.general
      guard let current = pasteboard.string else { return }
      guard current.contains(cid) else { return }
      pasteboard.string = ""
      debugLog("Cleared consumed pasteboard cid", extra: ["cid": cid])
    }
  #endif
}

// MARK: - Optional native wrapper lifecycle contract
// These Objective-C selectors let a wrapper detect support before enabling the
// protocol, without requiring a newer core's Swift Config initializer to compile.
extension LinkMe {
  private struct LifecycleHeader: Sendable {
    let owner: String
    let generation: Int
  }

  private func resetLifecycleOwner() {
    lifecycleOwner = nil
    lifecycleClientGeneration = 0
    lifecycleLastCommand = nil
  }

  private func lifecycleInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          let integer = Int(number.stringValue), integer >= 0, integer <= 9_007_199_254_740_991 else { return nil }
    return integer
  }

  private func lifecycleHeader(_ args: NSDictionary) -> LifecycleHeader? {
    guard lifecycleInteger(args["contractVersion"]) == 1,
          let owner = args["ownerId"] as? String, !owner.isEmpty, owner.utf8.count <= 128,
          let generation = lifecycleInteger(args["clientGeneration"]) else { return nil }
    return LifecycleHeader(owner: owner, generation: generation)
  }

  private func lifecycleReply(_ header: LifecycleHeader?, error: String? = nil, duplicate: Bool = false) -> [String: Any] {
    var result: [String: Any] = ["contractVersion": 1, "ok": error == nil]
    if let header { result["ownerId"] = header.owner; result["clientGeneration"] = header.generation }
    if let error { result["error"] = error }
    if duplicate { result["duplicate"] = true }
    return result
  }

  private func lifecycleFrame(_ header: LifecycleHeader, payload: LinkPayload?) -> NSDictionary {
    var result = lifecycleReply(header)
    if let payload, let data = try? JSONEncoder().encode(payload),
       let json = try? JSONSerialization.jsonObject(with: data) { result["payload"] = json }
    else { result["payload"] = NSNull() }
    return result as NSDictionary
  }

  private func recordLifecycle(_ header: LifecycleHeader, signature: Data) {
    lifecycleKnownGenerations[header.owner] = header.generation
    lifecycleOwnerOrder.removeAll { $0 == header.owner }
    lifecycleOwnerOrder.append(header.owner)
    if lifecycleOwnerOrder.count > 64 { lifecycleKnownGenerations.removeValue(forKey: lifecycleOwnerOrder.removeFirst()) }
    lifecycleLastCommand = (header.owner, header.generation, signature)
    lifecycleClientGeneration = header.generation
  }

  @objc public func linkmeLifecycleVersion() -> NSNumber { 1 }

  @objc(linkmeLifecycle:)
  public func linkmeLifecycle(_ args: NSDictionary) -> NSDictionary {
    guard let header = lifecycleHeader(args), let action = args["action"] as? String else {
      return lifecycleReply(nil, error: "invalid_args") as NSDictionary
    }
    var normalized: [String: Any] = ["action": action]
    var preparedConfig: Config?
    var identity: String?
    var consent = false
    switch action {
    case "configure":
      guard let raw = args["baseUrl"] as? String, let url = URL(string: raw),
            ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
            url.query == nil, url.fragment == nil,
            let timeout = lifecycleInteger(args["requestTimeoutMs"] is NSNull ? 15000 : (args["requestTimeoutMs"] ?? 15000)), timeout > 0, timeout <= 2_147_483_647 else {
        return lifecycleReply(header, error: "invalid_args") as NSDictionary
      }
      for key in ["sendDeviceInfo", "includeVendorId", "includeAdvertisingId", "debug"] {
        if let value = args[key], !(value is NSNull), !(value is NSNumber && CFGetTypeID(value as! NSNumber) == CFBooleanGetTypeID()) {
          return lifecycleReply(header, error: "invalid_args") as NSDictionary
        }
      }
      for key in ["appId", "appKey"] {
        if let value = args[key], !(value is NSNull), !(value is String) { return lifecycleReply(header, error: "invalid_args") as NSDictionary }
      }
      let config = Config(baseUrl: url, appId: args["appId"] as? String, appKey: args["appKey"] as? String,
                          sendDeviceInfo: args["sendDeviceInfo"] as? Bool ?? true,
                          includeVendorId: args["includeVendorId"] as? Bool ?? true,
                          includeAdvertisingId: args["includeAdvertisingId"] as? Bool ?? false,
                          debug: args["debug"] as? Bool ?? false, requestTimeout: Double(timeout) / 1000)
      preparedConfig = config
      normalized.merge(["baseUrl": raw, "appId": config.appId as Any? ?? NSNull(), "appKey": config.appKey as Any? ?? NSNull(),
                        "sendDeviceInfo": config.sendDeviceInfo, "includeVendorId": config.includeVendorId,
                        "includeAdvertisingId": config.includeAdvertisingId, "debug": config.debug, "requestTimeoutMs": timeout]) { _, new in new }
    case "setUserId":
      guard args.allKeys.contains(where: { ($0 as? String) == "userId" }), args["userId"] is String || args["userId"] is NSNull else {
        return lifecycleReply(header, error: "invalid_args") as NSDictionary
      }
      identity = args["userId"] as? String
      if let identity, identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return lifecycleReply(header, error: "invalid_args") as NSDictionary }
      normalized["userId"] = identity as Any? ?? NSNull()
    case "setAdvertisingConsent":
      guard let value = args["granted"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
        return lifecycleReply(header, error: "invalid_args") as NSDictionary
      }
      consent = value.boolValue; normalized["granted"] = consent
    case "cancelPendingRequests", "dispose", "setReady": break
    case "track":
      guard let event = args["event"] as? String, !event.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            args["properties"] == nil || args["properties"] is NSNull || args["properties"] is [String: Any] else {
        return lifecycleReply(header, error: "invalid_args") as NSDictionary
      }
    default: return lifecycleReply(header, error: "unsupported_action") as NSDictionary
    }
    guard let signature = try? JSONSerialization.data(withJSONObject: normalized, options: .sortedKeys) else {
      return lifecycleReply(header, error: "invalid_args") as NSDictionary
    }
    return withState {
      let mutation = !["track", "setReady"].contains(action)
      if mutation, let known = lifecycleKnownGenerations[header.owner] {
        if header.generation < known { return lifecycleReply(header, error: "stale_generation") as NSDictionary }
        if header.generation == known {
          if let last = lifecycleLastCommand, last.owner == header.owner, last.generation == header.generation, last.signature == signature {
            return lifecycleReply(header, duplicate: true) as NSDictionary
          }
          return lifecycleReply(header, error: "generation_conflict") as NSDictionary
        }
      }
      if action == "configure" {
        guard lifecycleOwner == nil || lifecycleOwner == header.owner else { return lifecycleReply(header, error: "owner_conflict") as NSDictionary }
        configure(config: preparedConfig!)
        lifecycleOwner = header.owner
      } else {
        guard lifecycleOwner == header.owner, config != nil else { return lifecycleReply(header, error: "owner_changed") as NSDictionary }
        if !mutation, header.generation != lifecycleClientGeneration { return lifecycleReply(header, error: "stale_generation") as NSDictionary }
        switch action {
        case "cancelPendingRequests": invalidateCurrentWork()
        case "dispose": dispose()
        case "setUserId": invalidateCurrentWork(); userId = identity
        case "setAdvertisingConsent": invalidateCurrentWork(); advertisingConsentEnabled = consent
        case "setReady": setReady()
        case "track": track(event: args["event"] as! String, props: args["properties"] as? [String: Any])
        default: break
        }
      }
      if mutation { recordLifecycle(header, signature: signature) }
      return lifecycleReply(header) as NSDictionary
    }
  }

  @objc(linkmeLifecycleRead:completion:)
  public func linkmeLifecycleRead(_ args: NSDictionary, completion: @escaping (NSDictionary) -> Void) {
    let callback = CallbackBox(completion)
    guard let header = lifecycleHeader(args), let action = args["action"] as? String,
          ["getInitialLink", "claimDeferredIfAvailable"].contains(action) else {
      let message = lifecycleReply(nil, error: "invalid_args") as NSDictionary
      let box = CallbackBox<Bool> { _ in callback.call(message) }
      queue.async { box.call(false) }
      return
    }
    withState {
      guard lifecycleOwner == header.owner, config != nil, lifecycleClientGeneration == header.generation else {
        let box = CallbackBox<Bool> { _ in callback.call(self.lifecycleReply(header, error: "owner_changed") as NSDictionary) }
        queue.async { box.call(false) }
        return
      }
      let deliver: (LinkPayload?) -> Void = { [weak self] payload in
        guard let self else {
          callback.call(["contractVersion": 1, "ok": false, "ownerId": header.owner, "clientGeneration": header.generation, "error": "disposed"])
          return
        }
        self.withState {
          guard self.lifecycleOwner == header.owner, self.lifecycleClientGeneration == header.generation else {
            callback.call(self.lifecycleReply(header, error: "owner_changed") as NSDictionary)
            return
          }
          callback.call(self.lifecycleFrame(header, payload: payload))
        }
      }
      if action == "getInitialLink" { getInitialLink(completion: deliver) }
      else { claimDeferredIfAvailable(completion: deliver) }
    }
  }

  @objc(linkmeLifecycleListen:)
  public func linkmeLifecycleListen(_ listener: @escaping (NSDictionary) -> Void) -> NSString {
    withState {
      let token = UUID().uuidString
      let box = CallbackBox(listener)
      lifecycleSubscriptions[token] = addListener { [weak self] payload in
        guard let self, let owner = self.lifecycleOwner else { return }
        box.call(self.lifecycleFrame(LifecycleHeader(owner: owner, generation: self.lifecycleClientGeneration), payload: payload))
      }
      return token as NSString
    }
  }

  @objc(linkmeLifecycleUnlisten:)
  public func linkmeLifecycleUnlisten(_ token: NSString) {
    withState { lifecycleSubscriptions.removeValue(forKey: token as String)?() }
  }
}
