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
    public let params: [String:String]?
    public let utm: [String:String]?
    public let custom: [String:String]?

    public init(
        linkId: String? = nil,
        path: String? = nil,
        params: [String:String]? = nil,
        utm: [String:String]? = nil,
        custom: [String:String]? = nil
    ) {
        self.linkId = linkId
        self.path = path
        self.params = params
        self.utm = utm
        self.custom = custom
    }
}

public final class LinkMe: @unchecked Sendable {
    public static let shared = LinkMe()
    private init() {}

    public struct Config: Sendable {
        public let baseUrl: URL
        public let appId: String?
        public let appKey: String?
        public let enablePasteboard: Bool
        public let sendDeviceInfo: Bool
        public let includeVendorId: Bool
        public let includeAdvertisingId: Bool
        public init(
            baseUrl: URL,
            appId: String? = nil,
            appKey: String? = nil,
            enablePasteboard: Bool = false,
            sendDeviceInfo: Bool = true,
            includeVendorId: Bool = true,
            includeAdvertisingId: Bool = false
        ) {
            self.baseUrl = baseUrl
            self.appId = appId
            self.appKey = appKey
            self.enablePasteboard = enablePasteboard
            self.sendDeviceInfo = sendDeviceInfo
            self.includeVendorId = includeVendorId
            self.includeAdvertisingId = includeAdvertisingId
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

    public func configure(config: Config) {
        self.config = config
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
              let url = userActivity.webpageURL else { return false }
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
        guard let cfg = config else { completion(nil); return }
        let url = cfg.baseUrl.appendingPathComponent("api/deferred/claim")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        setHeaders(on: &req)
        var payload: [String: Any] = [
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "platform": "ios"
        ]
        if let dev = buildDevicePayload(), cfg.sendDeviceInfo { payload["device"] = dev }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            if let err = err { print("[LinkMeKit] deferred error=\(err.localizedDescription)"); completion(nil); return }
            guard let http = resp as? HTTPURLResponse else { print("[LinkMeKit] deferred no response"); completion(nil); return }
            if !(200..<300).contains(http.statusCode) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                print("[LinkMeKit] deferred status=\(http.statusCode) body=\(body)")
                completion(nil); return
            }
            guard let self = self, let data = data, let p = try? JSONDecoder().decode(LinkPayload.self, from: data) else { print("[LinkMeKit] deferred decode failed"); completion(nil); return }
            self.emit(payload: p)
            completion(p)
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
            "event": event,
            "platform": "ios",
            "timestamp": Int(Date().timeIntervalSince1970)
        ]
        if let userId { body["userId"] = userId }
        if let props { body["props"] = props }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: - Internal
    private func handleIncoming(url: URL) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.config != nil, self.isReady else {
                print("[LinkMeKit] queueing URL=\(url.absoluteString) ready=\(self.isReady) cfg=\(self.config != nil)")
                self.pendingURLs.append(url)
                return
            }
            print("[LinkMeKit] processing URL=\(url.absoluteString)")
            if let cid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cid" })?.value {
                self.resolveCid(cid)
            } else if url.scheme?.hasPrefix("http") == true {
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
        var comp = URLComponents(url: cfg.baseUrl.appendingPathComponent("api/deeplink"), resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "cid", value: cid)]
        guard let url = comp.url else { return }
        var req = URLRequest(url: url)
        setHeaders(on: &req)
        if let dev = buildDevicePayload(), cfg.sendDeviceInfo {
            if let json = try? JSONSerialization.data(withJSONObject: dev), let s = String(data: json, encoding: .utf8) {
                req.setValue(s, forHTTPHeaderField: "x-linkme-device")
            }
        }
        print("[LinkMeKit] GET /api/deeplink?cid=\(cid)")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            if let err = err { print("[LinkMeKit] deeplink error=\(err.localizedDescription)"); return }
            guard let http = resp as? HTTPURLResponse else { print("[LinkMeKit] deeplink no response"); return }
            if !(200..<300).contains(http.statusCode) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                print("[LinkMeKit] deeplink status=\(http.statusCode) body=\(body)")
                return
            }
            guard let self = self, let data = data, let payload = try? JSONDecoder().decode(LinkPayload.self, from: data) else { print("[LinkMeKit] deeplink decode failed"); return }
            self.emit(payload: payload)
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
        print("[LinkMeKit] POST /api/deeplink/resolve-url base=\(cfg.baseUrl.absoluteString) url=\(urlIn.absoluteString)")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            if let err = err { print("[LinkMeKit] resolve-url error=\(err.localizedDescription)"); return }
            guard let http = resp as? HTTPURLResponse else { print("[LinkMeKit] resolve-url no response"); return }
            if !(200..<300).contains(http.statusCode) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                print("[LinkMeKit] resolve-url status=\(http.statusCode) body=\(body)")
                return
            }
            guard let self = self, let data = data, let payload = try? JSONDecoder().decode(LinkPayload.self, from: data) else { print("[LinkMeKit] resolve-url decode failed"); return }
            self.emit(payload: payload)
        }.resume()
    }

    // Build device payload with consent-aware identifiers.
    private func buildDevicePayload() -> [String: Any]? {
        guard let cfg = config else { return nil }
        var dev: [String: Any] = [:]
        dev["platform"] = "ios"
        dev["bundleId"] = Bundle.main.bundleIdentifier ?? ""
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { dev["appVersion"] = v }
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
            if let idfv = UIDevice.current.identifierForVendor?.uuidString { dev["id_type"] = "idfv"; dev["device_id"] = idfv }
            #endif
        }
        // We do not request ATT here; integrator should enable this flag only after user consent.
        if advertisingConsentEnabled {
            consent["advertising"] = true
            #if canImport(AdSupport)
            #if canImport(AppTrackingTransparency)
            if #available(iOS 14, *) {
                if ATTrackingManager.trackingAuthorizationStatus == .authorized {
                    let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
                    if idfa != "00000000-0000-0000-0000-000000000000" { dev["id_type"] = "idfa"; dev["device_id"] = idfa }
                }
            } else {
                if ASIdentifierManager.shared().isAdvertisingTrackingEnabled {
                    let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
                    if idfa != "00000000-0000-0000-0000-000000000000" { dev["id_type"] = "idfa"; dev["device_id"] = idfa }
                }
            }
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

    #if canImport(UIKit)
    private func tryReadPasteboardToken() {
        guard let str = UIPasteboard.general.string,
              let url = URL(string: str),
              let cid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cid" })?.value else { return }
        resolveCid(cid)
    }
    #endif
}
