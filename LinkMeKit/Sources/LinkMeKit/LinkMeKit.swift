import Foundation

#if canImport(UIKit)
  import UIKit
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

  public init(
    linkId: String? = nil,
    path: String? = nil,
    params: [String: String]? = nil,
    utm: [String: String]? = nil,
    custom: [String: String]? = nil,
    url: String? = nil,
    isLinkMe: Bool? = nil
  ) {
    self.linkId = linkId
    self.path = path
    self.params = params
    self.utm = utm
    self.custom = custom
    self.url = url
    self.isLinkMe = isLinkMe
  }
}

public final class LinkMe: @unchecked Sendable {
  public static let shared = LinkMe()
  private init() {}

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
    public init(
      baseUrl: URL,
      appId: String? = nil,
      appKey: String? = nil,
      enablePasteboard: Bool = false,
      sendDeviceInfo: Bool = true,
      includeVendorId: Bool = true,
      includeAdvertisingId: Bool = false,
      debug: Bool = false
    ) {
      self.baseUrl = baseUrl
      self.appId = appId
      self.appKey = appKey
      self.enablePasteboard = enablePasteboard
      self.sendDeviceInfo = sendDeviceInfo
      self.includeVendorId = includeVendorId
      self.includeAdvertisingId = includeAdvertisingId
      self.debug = debug
    }
  }

  private var config: Config?
  private var userId: String?
  private var lastPayload: LinkPayload?
  private var listeners: [(LinkPayload) -> Void] = []
  private var pendingURLs: [URL] = []
  private let queue = DispatchQueue(label: "me.link.linkmekit")
  private var advertisingConsentEnabled: Bool = false
  private var isReady: Bool = false
  private var debugEnabled: Bool { config?.debug ?? false }
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

  public func configure(config: Config) {
    self.config = config
    debugLog(
      "Configured",
      extra: [
        "baseUrl": config.baseUrl.absoluteString,
        "appId": config.appId ?? "none",
        "debug": config.debug
      ]
    )
    // Initialize advertising consent from config flag; can be overridden later
    self.advertisingConsentEnabled = config.includeAdvertisingId
    // Configure now acts as "setReady": set config and begin processing queued links
    self.isReady = true
    queue.async { [weak self] in
      self?.drainPending()
      #if canImport(UIKit)
        if config.enablePasteboard { self?.tryReadPasteboardToken() }
      #endif
    }
  }

  // First release: no deprecated aliases.

  public func getInitialLink(completion: @escaping (LinkPayload?) -> Void) {
    queue.async { [weak self] in completion(self?.lastPayload) }
  }

  @discardableResult
  public func addListener(_ handler: @escaping (LinkPayload) -> Void) -> () -> Void {
    listeners.append(handler)
    let idx = listeners.count - 1
    return { [weak self] in self?.listeners.remove(at: idx) }
  }

  // For wiring test only: broadcast a fake payload
  public func _debugEmit(_ payload: LinkPayload) {
    for h in listeners { h(payload) }
    lastPayload = payload
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

    @discardableResult
    public func handle(url: URL) -> Bool {
      handleIncoming(url: url)
      return true
    }

  // First release: no deprecated aliases.
  #endif

  public func claimDeferredIfAvailable(completion: @escaping (LinkPayload?) -> Void) {
    guard config != nil else {
      completion(nil)
      return
    }
    
    // First, try to read cid from pasteboard (set by li-nk.me during App Store redirect)
    #if canImport(UIKit)
    if let cid = readPasteboardCid() {
      debugLog("Found cid in pasteboard, using direct claim")
      resolveCidWithCompletion(cid, completion: completion)
      return
    }
    #endif
    
    // Fallback to fingerprint-based claim
    debugLog("No pasteboard cid, using fingerprint claim")
    claimViaFingerprint(completion: completion)
  }
  
  private func claimViaFingerprint(completion: @escaping (LinkPayload?) -> Void) {
    guard let cfg = config else {
      completion(nil)
      return
    }
    let url = cfg.baseUrl.appendingPathComponent("api/deferred/claim")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    setHeaders(on: &req)
    var payload: [String: Any] = [
      "bundleId": Bundle.main.bundleIdentifier ?? "",
      "platform": "ios",
    ]
    if let dev = buildDevicePayload(), cfg.sendDeviceInfo { payload["device"] = dev }
    req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    debugLog("POST /api/deferred/claim", extra: ["payload": payload])
    URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
      if let err = err {
        self?.debugLog("Deferred claim error", extra: ["error": err.localizedDescription])
        completion(nil)
        return
      }
      guard let http = resp as? HTTPURLResponse else {
        self?.debugLog("Deferred claim missing HTTP response")
        completion(nil)
        return
      }
      if !(200..<300).contains(http.statusCode) {
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        self?.debugLog(
          "Deferred claim HTTP error",
          extra: ["status": http.statusCode, "body": body]
        )
        completion(nil)
        return
      }
      guard let self = self, let data = data,
        let p = try? JSONDecoder().decode(LinkPayload.self, from: data)
      else {
        self?.debugLog("Deferred claim decode failed")
        completion(nil)
        return
      }
      let payload = self.annotatePayload(p, isLinkMe: true)
      self.debugLog("Deferred claim payload received", extra: ["linkId": payload.linkId ?? "none"])
      self.emit(payload: payload)
      completion(payload)
    }.resume()
  }
  
  private func resolveCidWithCompletion(_ cid: String, completion: @escaping (LinkPayload?) -> Void) {
    guard let cfg = config else {
      completion(nil)
      return
    }
    var comp = URLComponents(
      url: cfg.baseUrl.appendingPathComponent("api/deeplink"), resolvingAgainstBaseURL: false)!
    comp.queryItems = [URLQueryItem(name: "cid", value: cid)]
    guard let url = comp.url else {
      completion(nil)
      return
    }
    var req = URLRequest(url: url)
    setHeaders(on: &req)
    if let dev = buildDevicePayload(), cfg.sendDeviceInfo {
      if let json = try? JSONSerialization.data(withJSONObject: dev),
        let s = String(data: json, encoding: .utf8)
      {
        req.setValue(s, forHTTPHeaderField: "x-linkme-device")
      }
    }
    debugLog("GET /api/deeplink for cid", extra: ["cid": cid, "source": "pasteboard"])
    URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
      if let err = err {
        self?.debugLog("Pasteboard cid claim error", extra: ["error": err.localizedDescription])
        completion(nil)
        return
      }
      guard let http = resp as? HTTPURLResponse else {
        self?.debugLog("Pasteboard cid claim missing response")
        completion(nil)
        return
      }
      if !(200..<300).contains(http.statusCode) {
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        self?.debugLog(
          "Pasteboard cid HTTP error",
          extra: ["status": http.statusCode, "body": body]
        )
        completion(nil)
        return
      }
      guard let self = self, let data = data,
        let payload = try? JSONDecoder().decode(LinkPayload.self, from: data)
      else {
        self?.debugLog("Pasteboard cid claim decode failed")
        completion(nil)
        return
      }
      let annotated = self.annotatePayload(payload, isLinkMe: true)
      self.debugLog(
        "Pasteboard cid claim payload received",
        extra: ["linkId": annotated.linkId ?? "none"]
      )
      self.emit(payload: annotated)
      completion(annotated)
    }.resume()
  }

  public func setUserId(_ id: String) { userId = id }

  // Opt-in/out of advertising identifier usage at runtime, typically after ATT prompt.
  // Persist this in your app if you want it to survive restarts.
  public func setAdvertisingConsent(_ granted: Bool) {
    queue.async { [weak self] in self?.advertisingConsentEnabled = granted }
  }

  public func track(event: String, props: [String: Any]? = nil) {
    guard let cfg = config else { return }
    let url = cfg.baseUrl.appendingPathComponent("api/app-events")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    setHeaders(on: &req)
    var body: [String: Any] = [
      "type": event,
      "platform": "ios",
      "timestamp": Int(Date().timeIntervalSince1970),
    ]
    if let userId { body["userId"] = userId }
    if let props,
      let data = try? JSONSerialization.data(withJSONObject: props),
      let detail = String(data: data, encoding: .utf8)
    {
      body["detail"] = detail
    }
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    URLSession.shared.dataTask(with: req).resume()
  }

  // MARK: - Internal
  private func handleIncoming(url: URL) {
    queue.async { [weak self] in
      guard let self = self else { return }
      guard self.config != nil, self.isReady else {
        self.debugLog(
          "Queueing URL",
          extra: ["url": url.absoluteString, "ready": self.isReady, "hasConfig": self.config != nil]
        )
        self.pendingURLs.append(url)
        return
      }
      self.debugLog("Processing URL", extra: ["url": url.absoluteString])
      if let cid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(
        where: { $0.name == "cid" })?.value
      {
        self.debugLog("Found cid parameter", extra: ["cid": cid])
        self.resolveCid(cid)
      } else if url.scheme?.hasPrefix("http") == true {
        self.debugLog("Resolving universal link", extra: ["url": url.absoluteString])
        self.resolveUniversalLink(url)
      }
    }
  }

  private func drainPending() {
    guard config != nil, isReady else { return }
    let urls = pendingURLs
    pendingURLs.removeAll()
    for u in urls { handleIncoming(url: u) }
  }

  // Call when user consent state is finalized and you want to start network calls.
  public func setReady() {
    queue.async { [weak self] in
      guard let self = self else { return }
      self.isReady = true
      self.drainPending()
    }
  }

  private func resolveCid(_ cid: String) {
    guard let cfg = config else { return }
    var comp = URLComponents(
      url: cfg.baseUrl.appendingPathComponent("api/deeplink"), resolvingAgainstBaseURL: false)!
    comp.queryItems = [URLQueryItem(name: "cid", value: cid)]
    guard let url = comp.url else { return }
    var req = URLRequest(url: url)
    setHeaders(on: &req)
    if let dev = buildDevicePayload(), cfg.sendDeviceInfo {
      if let json = try? JSONSerialization.data(withJSONObject: dev),
        let s = String(data: json, encoding: .utf8)
      {
        req.setValue(s, forHTTPHeaderField: "x-linkme-device")
      }
    }
    debugLog("GET /api/deeplink", extra: ["cid": cid])
    URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
      if let err = err {
        self?.debugLog("Deeplink error", extra: ["error": err.localizedDescription])
        return
      }
      guard let http = resp as? HTTPURLResponse else {
        self?.debugLog("Deeplink missing response")
        return
      }
      if !(200..<300).contains(http.statusCode) {
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        self?.debugLog("Deeplink HTTP error", extra: ["status": http.statusCode, "body": body])
        return
      }
      guard let self = self, let data = data,
        let payload = try? JSONDecoder().decode(LinkPayload.self, from: data)
      else {
        self?.debugLog("Deeplink decode failed")
        return
      }
      let annotated = self.annotatePayload(payload, isLinkMe: true)
      self.debugLog("Deeplink payload received", extra: ["linkId": annotated.linkId ?? "none"])
      self.emit(payload: annotated)
    }.resume()
  }

  private func resolveUniversalLink(_ urlIn: URL) {
    guard let cfg = config else { return }
    let url = cfg.baseUrl.appendingPathComponent("api/deeplink/resolve-url")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    setHeaders(on: &req)
    var body: [String: Any] = ["url": urlIn.absoluteString]
    if let dev = buildDevicePayload(), cfg.sendDeviceInfo { body["device"] = dev }
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    debugLog(
      "POST /api/deeplink/resolve-url",
      extra: ["baseUrl": cfg.baseUrl.absoluteString, "url": urlIn.absoluteString]
    )
    URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
      if let err = err {
        self?.debugLog("Resolve-url error", extra: ["error": err.localizedDescription])
        return
      }
      guard let http = resp as? HTTPURLResponse else {
        self?.debugLog("Resolve-url missing response")
        return
      }
      if !(200..<300).contains(http.statusCode) {
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if self?.isDomainNotFound(body) == true, let fallback = self?.buildBasicUniversalPayload(url: urlIn) {
          self?.debugLog("Resolve-url non-linkme", extra: ["url": urlIn.absoluteString])
          self?.emit(payload: fallback)
          return
        }
        self?.debugLog("Resolve-url HTTP error", extra: ["status": http.statusCode, "body": body])
        return
      }
      guard let self = self, let data = data,
        let payload = try? JSONDecoder().decode(LinkPayload.self, from: data)
      else {
        self?.debugLog("Resolve-url decode failed")
        return
      }
      let annotated = self.annotatePayload(payload, isLinkMe: true)
      self.debugLog("Resolve-url payload received", extra: ["linkId": annotated.linkId ?? "none"])
      self.emit(payload: annotated)
    }.resume()
  }

  // Build device payload with consent-aware identifiers.
  private func buildDevicePayload() -> [String: Any]? {
    guard let cfg = config else { return nil }
    var dev: [String: Any] = [:]
    dev["platform"] = "ios"
    dev["bundleId"] = Bundle.main.bundleIdentifier ?? ""
    if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
      dev["appVersion"] = v
    }
    if let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String { dev["buildNumber"] = b }
    #if canImport(UIKit)
      dev["osVersion"] = UIDevice.current.systemVersion
      dev["deviceModel"] = UIDevice.current.model
    #endif
    dev["locale"] = Locale.current.identifier
    dev["timezone"] = TimeZone.current.identifier
    var consent: [String: Any] = [:]
    if cfg.includeVendorId {
      consent["vendor"] = true
      #if canImport(UIKit)
        if let idfv = UIDevice.current.identifierForVendor?.uuidString {
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

  private func emit(payload: LinkPayload) {
    queue.async { [weak self] in
      guard let self = self else { return }
      self.lastPayload = payload
      for h in self.listeners { h(payload) }
    }
  }

  private func annotatePayload(_ payload: LinkPayload, isLinkMe: Bool? = nil, url: String? = nil) -> LinkPayload {
    return LinkPayload(
      linkId: payload.linkId,
      path: payload.path,
      params: payload.params,
      utm: payload.utm,
      custom: payload.custom,
      url: payload.url ?? url,
      isLinkMe: payload.isLinkMe ?? isLinkMe
    )
  }

  private func buildBasicUniversalPayload(url: URL) -> LinkPayload? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let (params, utm) = splitQueryItems(components.queryItems)
    return LinkPayload(
      path: url.path.isEmpty ? "/" : url.path,
      params: params,
      utm: utm,
      url: url.absoluteString,
      isLinkMe: false
    )
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
      guard let cid = readPasteboardCid() else { return }
      resolveCid(cid)
    }
    
    /// Reads a LinkMe cid from pasteboard.
    ///
    /// Accepts:
    /// - `linkme:cid=<hex>`
    /// - Any URL containing `?cid=<hex>` (host may be a branded domain / CNAME)
    /// - Any clipboard text containing `cid=<hex>`
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
        return cid
      }

      if let m = raw.range(of: #"(?:^|[?&\s])cid=([a-fA-F0-9]{8,64})(?:$|[&\s])"#, options: .regularExpression) {
        let chunk = String(raw[m])
        if let cidRange = chunk.range(of: #"[a-fA-F0-9]{8,64}"#, options: .regularExpression) {
          let cid = String(chunk[cidRange])
          return isValidCid(cid) ? cid : nil
        }
      }

      return nil
    }
  #endif
}
