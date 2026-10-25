import XCTest
@testable import LinkMeKit

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data?))?
    static var onStart: ((URLRequest) -> Void)?
    static var responseDelay: TimeInterval = 0
    static var stallBody = false
    static var onStop: ((URLRequest) -> Void)?

    private var pendingWork: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.onStart?(request)
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard let self, !work.isCancelled, let handler = Self.handler else { return }
            let (response, data) = handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            if !Self.stallBody { self.client?.urlProtocolDidFinishLoading(self) }
        }
        pendingWork = work
        let delay = Self.responseDelay
        if delay == 0 {
            DispatchQueue.global().async(execute: work)
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    override func stopLoading() {
        Self.onStop?(request)
        pendingWork?.cancel()
        pendingWork = nil
    }
}

private final class ControlledTask: RequestTask, @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations = 0
    private let onResume: () -> Void
    init(onResume: @escaping () -> Void) { self.onResume = onResume }
    func resume() { onResume() }
    func cancel() { lock.lock(); cancellations += 1; lock.unlock() }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
}

/// Intentionally ignores cancellation and can complete a request more than once.
private final class ControlledTransport: @unchecked Sendable {
    struct Operation {
        let request: URLRequest
        let task: ControlledTask
        let completion: NetworkCompletion
    }
    private let lock = NSLock()
    private var entries: [Operation] = []
    private var onStart: ((Int, URLRequest) -> Void)?
    var operations: [Operation] { lock.lock(); defer { lock.unlock() }; return entries }
    func reset() { lock.lock(); onStart = nil; entries.removeAll(); lock.unlock() }
    func setOnStart(_ handler: @escaping (Int, URLRequest) -> Void) {
        lock.lock(); onStart = handler; lock.unlock()
    }
    func makeTask(_ request: URLRequest, completion: @escaping NetworkCompletion) -> RequestTask {
        lock.lock()
        let index = entries.count
        let task = ControlledTask { [weak self] in
            guard let self else { return }
            self.lock.lock(); let callback = self.onStart; self.lock.unlock()
            callback?(index, request)
        }
        entries.append(Operation(request: request, task: task, completion: completion))
        lock.unlock()
        return task
    }
    func reply(_ index: Int, body: String, status: Int = 200) {
        let operation = operations[index]
        operation.completion(Data(body.utf8), HTTPURLResponse(url: operation.request.url!, statusCode: status, httpVersion: nil, headerFields: nil), nil)
    }
}

final class LinkMeKitTests: XCTestCase {
    private let baseURL = URL(string: "https://edge.example.test")!
    private var clients: [LinkMe] = []
    private var transports: [ControlledTransport] = []

    override func tearDown() {
        clients.forEach { $0.dispose() }
        clients.removeAll()
        transports.forEach { $0.reset() }
        transports.removeAll()
        LinkMe.shared.dispose()
        StubURLProtocol.handler = nil
        StubURLProtocol.onStart = nil
        StubURLProtocol.responseDelay = 0
        StubURLProtocol.stallBody = false
        StubURLProtocol.onStop = nil
        super.tearDown()
    }

    private func makeClient(timeout: TimeInterval = 15) -> LinkMe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = LinkMe(
            urlSession: URLSession(configuration: configuration),
            requestTimeout: timeout,
            pasteboardTokenProvider: { nil }
        )
        clients.append(client)
        return client
    }

    private func makeControlledClient(deliveryQueue: DispatchQueue = DispatchQueue(label: "test.linkme.delivery"),
                                      open: (@MainActor (URL) -> Void)? = nil) -> (LinkMe, ControlledTransport) {
        let transport = ControlledTransport()
        transports.append(transport)
        let client = LinkMe(makeTask: transport.makeTask, openExternalURL: open, deliveryQueue: deliveryQueue,
                            pasteboardTokenProvider: { nil })
        clients.append(client)
        return (client, transport)
    }

    func testConfigure() {
        let url = URL(string: "https://li-nk.me")!
        LinkMe.shared.configure(config: .init(
            baseUrl: url,
            appId: nil,
            appKey: nil,
            enablePasteboard: false,
            sendDeviceInfo: false,
            includeVendorId: false,
            includeAdvertisingId: false
        ))
        let payload = LinkPayload(path: "/welcome", isLinkMe: true, cid: "abc12345", duplicate: true)
        let encoded = try! JSONEncoder().encode(payload)
        let decoded = try! JSONDecoder().decode(LinkPayload.self, from: encoded)
        XCTAssertEqual(decoded.path, "/welcome")
        XCTAssertEqual(decoded.isLinkMe, true)
        XCTAssertEqual(decoded.cid, "abc12345")
        XCTAssertEqual(decoded.duplicate, true)
        XCTAssertNil(LinkMe.Config(baseUrl: url).requestTimeout)
        XCTAssertEqual(LinkMe.Config(baseUrl: url, requestTimeout: 0.25).requestTimeout, 0.25)
        for timeout in [0, -1, TimeInterval.nan, .infinity, 2_147_484] {
            XCTAssertEqual(LinkMe.Config(baseUrl: url, requestTimeout: timeout).requestTimeout, 15)
        }
    }

    func testListenerRemovalIsIdempotentAndIndependent() {
        let first = expectation(description: "first listener")
        let second = expectation(description: "second listener")
        let client = makeClient()
        client.configure(config: .init(baseUrl: baseURL, sendDeviceInfo: false))
        let removeFirst = client.addListener { _ in first.fulfill() }
        let removeSecond = client.addListener { _ in second.fulfill() }

        client._debugEmit(LinkPayload(path: "/one"))
        wait(for: [first, second], timeout: 1)
        removeFirst()
        removeFirst()
        removeSecond()
        removeSecond()
    }

    func testMetadataOnlyAttributionDoesNotReachRoutingListeners() throws {
        let data = try JSONSerialization.data(withJSONObject: ["navigationAllowed": false, "claimId": "inferred", "attributionStatus": "inferred"])
        XCTAssertEqual(try JSONDecoder().decode(LinkPayload.self, from: data).navigationAllowed, false)
        let malformed = Data(#"{"navigationAllowed":"false","path":"/must-not-route"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LinkPayload.self, from: malformed))
        let received = expectation(description: "metadata response produced")
        let routed = expectation(description: "no routing callback")
        routed.isInverted = true
        StubURLProtocol.handler = { request in
            received.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let client = makeClient()
        client.configure(config: .init(baseUrl: baseURL, appId: "app", sendDeviceInfo: false))
        let remove = client.addListener { _ in routed.fulfill() }
        defer { remove() }
        client.handle(url: URL(string: "https://links.example.test/welcome")!)
        wait(for: [received, routed], timeout: 0.4)
    }

    func testClaimPolicyMetadataSurvivesUrlAnnotationAndDelivery() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/link-payload.claim-policy-v2.json"))
        let delivered = expectation(description: "claim metadata delivered")
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, data)
        }
        let client = makeClient()
        client.configure(config: .init(baseUrl: baseURL, appId: "app", sendDeviceInfo: false))
        let remove = client.addListener { payload in
            XCTAssertEqual(payload.claimMethod, "direct_cid")
            XCTAssertEqual(payload.matchConfidence, "high")
            XCTAssertEqual(payload.attributionStatus, "deterministic")
            XCTAssertEqual(payload.claimPolicyVersion, 2)
            XCTAssertEqual(payload.contractVersion, 1)
            XCTAssertNotNil(payload.claimId)
            delivered.fulfill()
        }
        defer { remove() }
        client.handle(url: URL(string: "https://links.example.test/welcome")!)
        wait(for: [delivered], timeout: 1)
    }

    func testSharedV1GoldenFixtureRoundTrips() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/link-payload.valid.json")
        let payload = try JSONDecoder().decode(LinkPayload.self, from: Data(contentsOf: fixtureURL))
        XCTAssertEqual(payload.cid, "cid-golden-001")
        XCTAssertEqual(payload.linkId, "link-golden-001")
        XCTAssertEqual(payload.path, "/welcome/春")
        XCTAssertEqual(payload.params?["quote"], "He said \"go\"")
        XCTAssertEqual(payload.custom?["control"], "line\nfeed")
        XCTAssertEqual(payload.duplicate, false)
    }

    func testCrossPlatformUrlHandlerAcceptsForwardedUrl() {
        XCTAssertTrue(makeClient().handle(url: URL(string: "myapp://welcome?cid=abc12345")!))
    }

    func testUniversalLinkResolutionUsesInjectedTransportAndContractHeaders() {
        let requestReceived = expectation(description: "request received")
        let payloadReceived = expectation(description: "payload received")
        var capturedRequest: URLRequest?
        StubURLProtocol.handler = { request in
            capturedRequest = request
            requestReceived.fulfill()
            let body = Data(#"{"linkId":"link-1","path":"/welcome","cid":"cid-1"}"#.utf8)
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                body
            )
        }

        let client = makeClient()
        client.configure(config: .init(
            baseUrl: baseURL,
            appId: "app-1",
            appKey: "key-1",
            sendDeviceInfo: false
        ))
        let removeListener = client.addListener { payload in
            XCTAssertEqual(payload.linkId, "link-1")
            XCTAssertEqual(payload.path, "/welcome")
            XCTAssertEqual(payload.isLinkMe, true)
            payloadReceived.fulfill()
        }
        defer { removeListener() }

        XCTAssertTrue(client.handle(url: URL(string: "https://links.example.test/welcome?source=mail")!))
        wait(for: [requestReceived, payloadReceived], timeout: 1)

        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/deeplink/resolve-url")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "x-app-id"), "app-1")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "x-api-key"), "key-1")
        XCTAssertEqual(capturedRequest?.timeoutInterval, 15)
        if let data = capturedRequest.flatMap(Self.bodyData),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            XCTAssertEqual(json["url"] as? String, "https://links.example.test/welcome?source=mail")
        } else {
            XCTFail("Expected a JSON request body")
        }
    }

    func testHttpFailureDoesNotEmitPayload() {
        let requestReceived = expectation(description: "request received")
        let payloadReceived = expectation(description: "payload should not be delivered")
        payloadReceived.isInverted = true
        StubURLProtocol.handler = { request in
            requestReceived.fulfill()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":"temporarily_unavailable"}"#.utf8)
            )
        }

        let client = makeClient()
        client.configure(config: .init(baseUrl: baseURL, sendDeviceInfo: false))
        let removeListener = client.addListener { _ in payloadReceived.fulfill() }
        defer { removeListener() }

        XCTAssertTrue(client.handle(url: URL(string: "https://links.example.test/failure")!))
        wait(for: [requestReceived, payloadReceived], timeout: 0.25)
    }

    func testRequestDeadlineCancelsSlowTransportWithoutDelivery() {
        let requestReceived = expectation(description: "request received")
        let payloadReceived = expectation(description: "payload should not be delivered")
        payloadReceived.isInverted = true
        StubURLProtocol.responseDelay = 0.2
        StubURLProtocol.onStart = { _ in requestReceived.fulfill() }
        StubURLProtocol.handler = { request in
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"path":"/too-late"}"#.utf8)
            )
        }

        let client = makeClient(timeout: 0.05)
        client.configure(config: .init(baseUrl: baseURL, sendDeviceInfo: false))
        let removeListener = client.addListener { _ in payloadReceived.fulfill() }
        defer { removeListener() }

        XCTAssertTrue(client.handle(url: URL(string: "https://links.example.test/slow")!))
        wait(for: [requestReceived, payloadReceived], timeout: 0.35)
    }

    func testConfiguredDeadlineSettlesOnceDespiteIgnoredCancellationAndAllowsRecovery() {
        let (client, transport) = makeControlledClient()
        let started = expectation(description: "first request")
        transport.setOnStart { _, _ in started.fulfill() }
        client.configure(config: .init(baseUrl: baseURL, sendDeviceInfo: false, requestTimeout: 0.03))
        let timedOut = expectation(description: "deadline completion exactly once")
        timedOut.assertForOverFulfill = true
        client.claimDeferredIfAvailable { payload in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertNil(payload)
            timedOut.fulfill()
        }
        wait(for: [started, timedOut], timeout: 1)
        XCTAssertEqual(transport.operations[0].request.timeoutInterval, 0.03)
        XCTAssertEqual(transport.operations[0].task.cancelCount, 1)
        transport.reply(0, body: #"{"path":"/late"}"#)
        transport.reply(0, body: #"{"path":"/duplicate"}"#)
        let initial = expectation(description: "no late payload")
        client.getInitialLink { payload in XCTAssertNil(payload); initial.fulfill() }
        wait(for: [initial], timeout: 1)

        let recovery = expectation(description: "recovery response")
        transport.setOnStart { index, _ in transport.reply(index, body: #"{"path":"/recovered"}"#) }
        client.claimDeferredIfAvailable { payload in
            XCTAssertEqual(payload?.path, "/recovered")
            recovery.fulfill()
        }
        wait(for: [recovery], timeout: 1)
        XCTAssertEqual(transport.operations[1].task.cancelCount, 0)
    }

    func testLifecycleChangesCancelPendingClaimsAndIgnoreLateRouting() {
        for change in ["configure", "identity", "dispose", "cancel"] {
            let (client, transport) = makeControlledClient(open: { _ in XCTFail("Old browser launch") })
            client.configure(config: .init(baseUrl: baseURL, appId: "app-a", sendDeviceInfo: false))
            let started = expectation(description: "started \(change)")
            transport.setOnStart { _, _ in started.fulfill() }
            let completed = expectation(description: "cancelled \(change)")
            completed.assertForOverFulfill = true
            client.claimDeferredIfAvailable { payload in XCTAssertNil(payload); completed.fulfill() }
            wait(for: [started], timeout: 1)
            switch change {
            case "configure": client.configure(config: .init(baseUrl: baseURL, appId: "app-b", sendDeviceInfo: false))
            case "identity": client.setUserId("new-user")
            case "dispose": client.dispose()
            default: client.cancelPendingRequests()
            }
            wait(for: [completed], timeout: 1)
            XCTAssertEqual(transport.operations[0].task.cancelCount, 1)
            transport.reply(0, body: #"{"path":"/old","forceRedirectWeb":true,"webFallbackUrl":"https://must-not-open.example"}"#)
            let checked = expectation(description: "late response ignored")
            client.getInitialLink { payload in XCTAssertNil(payload); checked.fulfill() }
            wait(for: [checked], timeout: 1)
        }
    }

    func testResponseAlreadyQueuedForDeliveryCannotCrossAppConfiguration() {
        let delivery = DispatchQueue(label: "test.held.delivery")
        let (client, transport) = makeControlledClient(deliveryQueue: delivery)
        client.configure(config: .init(baseUrl: baseURL, appId: "app-a", sendDeviceInfo: false))
        let started = expectation(description: "request started")
        transport.setOnStart { _, _ in started.fulfill() }
        let completed = expectation(description: "stale delivery settled")
        client.claimDeferredIfAvailable { payload in XCTAssertNil(payload); completed.fulfill() }
        wait(for: [started], timeout: 1)
        delivery.suspend()
        transport.reply(0, body: #"{"path":"/old-app"}"#)
        client.configure(config: .init(baseUrl: baseURL, appId: "app-b", sendDeviceInfo: false))
        delivery.resume()
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(transport.operations[0].task.cancelCount, 0, "HTTP finished before reconfigure; delivery still needs a lifecycle guard")
    }

    func testScheduledBrowserLaunchIsCancelledByReconfiguration() {
        let (client, transport) = makeControlledClient(open: { _ in XCTFail("Stale scheduled browser launch") })
        client.configure(config: .init(baseUrl: baseURL, sendDeviceInfo: false))
        let started = expectation(description: "request started")
        transport.setOnStart { _, _ in started.fulfill() }
        let responseProcessed = DispatchSemaphore(value: 0)
        client.claimDeferredIfAvailable { payload in XCTAssertNil(payload); responseProcessed.signal() }
        wait(for: [started], timeout: 1)
        transport.reply(0, body: #"{"forceRedirectWeb":true,"webFallbackUrl":"https://browser.example/landing"}"#)
        // Hold main until the SDK has queued the browser operation, then revoke
        // its generation before main can perform that operation.
        XCTAssertEqual(responseProcessed.wait(timeout: .now() + 1), .success)
        client.configure(config: .init(baseUrl: baseURL, appId: "app-b", sendDeviceInfo: false))
        let drained = expectation(description: "main launch queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testForcedWebLaunchesOnceOnMainAndSuppressesRoutingAndCompletionPayload() {
        let opened = expectation(description: "one browser launch")
        opened.assertForOverFulfill = true
        let (client, transport) = makeControlledClient(open: { url in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(url.absoluteString, "https://browser.example/landing?utm_source=mail")
            opened.fulfill()
        })
        client.configure(config: .init(baseUrl: baseURL, sendDeviceInfo: false))
        let remove = client.addListener { _ in XCTFail("Forced web routed to app") }
        defer { remove() }
        transport.setOnStart { index, _ in
            transport.reply(index, body: #"{"forceRedirectWeb":true,"webFallbackUrl":"https://browser.example/landing?utm_source=mail"}"#)
            transport.reply(index, body: #"{"forceRedirectWeb":true,"webFallbackUrl":"https://browser.example/landing?utm_source=mail"}"#)
        }
        let completed = expectation(description: "forced response")
        completed.assertForOverFulfill = true
        client.claimDeferredIfAvailable { payload in XCTAssertNil(payload); completed.fulfill() }
        wait(for: [opened, completed], timeout: 1)
    }

    func testAppSwitchResetsInitialPayloadIdentityAndTrackingScope() {
        let (client, transport) = makeControlledClient()
        client.configure(config: .init(baseUrl: baseURL, appId: "app-a", appKey: "key-a", sendDeviceInfo: false))
        client.setUserId("user-a")
        transport.setOnStart { index, _ in transport.reply(index, body: #"{"path":"/old","cid":"old-cid","linkId":"old-link"}"#) }
        let first = expectation(description: "old claim")
        client.claimDeferredIfAvailable { payload in XCTAssertEqual(payload?.cid, "old-cid"); first.fulfill() }
        wait(for: [first], timeout: 1)
        client.configure(config: .init(baseUrl: baseURL, appId: "app-b", appKey: "key-b", sendDeviceInfo: false, requestTimeout: 2))
        let initial = expectation(description: "new initial state")
        client.getInitialLink { payload in XCTAssertNil(payload); initial.fulfill() }
        wait(for: [initial], timeout: 1)
        let tracked = expectation(description: "new app event")
        transport.setOnStart { index, request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-app-id"), "app-b")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "key-b")
            XCTAssertEqual(request.timeoutInterval, 2)
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["type"] as? String, "new-event")
            XCTAssertNil(body["userId"])
            XCTAssertNil(body["cid"])
            XCTAssertNil(body["linkId"])
            transport.reply(index, body: "{}")
            tracked.fulfill()
        }
        client.track(event: "new-event")
        wait(for: [tracked], timeout: 1)
    }

    func testReentrantLifecycleChangeStopsLaterListenersAndOldCompletion() {
        for change in ["configure", "identity", "dispose", "cancel"] {
            let (client, transport) = makeControlledClient()
            client.configure(config: .init(baseUrl: baseURL, appId: "app-a", sendDeviceInfo: false))
            transport.setOnStart { index, _ in transport.reply(index, body: #"{"path":"/route"}"#) }
            let first = expectation(description: "first listener \(change)")
            let removeFirst = client.addListener { _ in
                switch change {
                case "configure": client.configure(config: .init(baseUrl: self.baseURL, appId: "app-b", sendDeviceInfo: false))
                case "identity": client.setUserId("new-user")
                case "dispose": client.dispose()
                default: client.cancelPendingRequests()
                }
                first.fulfill()
            }
            let removeLater = client.addListener { _ in XCTFail("Later listener received invalidated result") }
            let completed = expectation(description: "old completion settled")
            client.claimDeferredIfAvailable { payload in XCTAssertNil(payload); completed.fulfill() }
            wait(for: [first, completed], timeout: 1)
            removeFirst(); removeFirst(); removeLater()
        }
    }

    func testPreconfigureURLIsProcessedOnceAndDoesNotReplayToNewListeners() {
        let (client, transport) = makeControlledClient()
        client.handle(url: URL(string: "https://links.example.test/?cid=cold1234")!)
        transport.setOnStart { index, request in
            XCTAssertEqual(request.url?.query, "cid=cold1234")
            transport.reply(index, body: #"{"path":"/cold"}"#)
        }
        let delivered = expectation(description: "cold URL delivery")
        let remove = client.addListener { payload in XCTAssertEqual(payload.path, "/cold"); delivered.fulfill() }
        client.configure(config: .init(baseUrl: baseURL, sendDeviceInfo: false))
        wait(for: [delivered], timeout: 1)
        remove()
        let removeLater = client.addListener { _ in XCTFail("Unexpected listener replay") }
        let initial = expectation(description: "explicit initial replay")
        client.getInitialLink { payload in XCTAssertEqual(payload?.path, "/cold"); initial.fulfill() }
        wait(for: [initial], timeout: 1)
        removeLater()
        XCTAssertEqual(transport.operations.count, 1)
    }

    func testDeadlineCancelsURLSessionWithAResponseBodyThatNeverFinishes() {
        let stopped = expectation(description: "URLSession transport cancelled during body read")
        StubURLProtocol.stallBody = true
        StubURLProtocol.onStop = { _ in stopped.fulfill() }
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"path":"#.utf8))
        }
        let client = makeClient()
        client.configure(config: .init(baseUrl: baseURL, sendDeviceInfo: false, requestTimeout: 0.05))
        let completed = expectation(description: "stalled body settled once")
        completed.assertForOverFulfill = true
        client.claimDeferredIfAvailable { payload in XCTAssertNil(payload); completed.fulfill() }
        wait(for: [stopped, completed], timeout: 1)
    }

    func testConcurrentCompletionCancellationAndDeadlineSettleEachRequestOnce() {
        final class Counts: @unchecked Sendable {
            let lock = NSLock()
            var values: [Int: Int] = [:]
            func increment(_ index: Int) { lock.lock(); values[index, default: 0] += 1; lock.unlock() }
        }
        let counts = Counts()
        let completed = expectation(description: "one completion per racing request")
        completed.expectedFulfillmentCount = 100
        completed.assertForOverFulfill = true
        let group = DispatchGroup()
        var scopes: [RequestScope] = []
        for index in 0..<100 {
            let transport = ControlledTransport()
            transports.append(transport)
            let scope = RequestScope(urlSession: .shared, makeTask: transport.makeTask)
            scopes.append(scope)
            var request = URLRequest(url: baseURL)
            request.timeoutInterval = 0.001
            scope.start(request) { _, _, _ in counts.increment(index); completed.fulfill() }
            group.enter()
            DispatchQueue.global().async { transport.reply(0, body: "{}"); group.leave() }
            group.enter()
            DispatchQueue.global().async { scope.cancelAll(); group.leave() }
        }
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
        scopes.forEach { $0.cancelAll() }
        counts.lock.lock()
        let result = counts.values
        counts.lock.unlock()
        XCTAssertEqual(result.count, 100)
        XCTAssertTrue(result.values.allSatisfy { $0 == 1 })
    }

    #if canImport(UIKit)
    func testUIKitMetadataForAQueuedURLIsCollectedOnMainWithoutVendorIdentifier() {
        let (client, transport) = makeControlledClient()
        let received = expectation(description: "UIKit metadata on main")
        transport.setOnStart { index, request in
            XCTAssertTrue(Thread.isMainThread)
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let device = body["device"] as! [String: Any]
            XCTAssertEqual(device["platform"] as? String, "ios")
            XCTAssertNotNil(device["osVersion"])
            XCTAssertNotNil(device["deviceModel"])
            XCTAssertNil(device["device_id"])
            transport.reply(index, body: #"{"path":"/metadata"}"#)
            received.fulfill()
        }
        let delivered = expectation(description: "metadata request delivered")
        let remove = client.addListener { _ in delivered.fulfill() }
        client.handle(url: URL(string: "https://links.example.test/metadata")!)
        client.configure(config: .init(baseUrl: baseURL, sendDeviceInfo: true, includeVendorId: false))
        wait(for: [received, delivered], timeout: 1)
        remove()
    }
    #endif

    private func lifecycleArgs(_ action: String, owner: String = "owner-a", generation: Int = 1,
                               extra: [String: Any] = [:]) -> NSDictionary {
        var args: [String: Any] = ["contractVersion": 1, "ownerId": owner, "clientGeneration": generation, "action": action]
        if action == "configure" {
            args.merge(["baseUrl": baseURL.absoluteString, "appId": "app-a", "appKey": "key-a", "sendDeviceInfo": false,
                        "includeVendorId": false, "requestTimeoutMs": 750]) { _, new in new }
        }
        args.merge(extra) { _, new in new }
        return args as NSDictionary
    }

    private func lifecycleCall(_ client: LinkMe, _ args: NSDictionary) -> NSDictionary {
        let object: NSObject = client
        XCTAssertTrue(object.responds(to: NSSelectorFromString("linkmeLifecycle:")))
        return object.perform(NSSelectorFromString("linkmeLifecycle:"), with: args)!.takeUnretainedValue() as! NSDictionary
    }

    private func lifecycleRead(_ client: LinkMe, _ args: NSDictionary, _ completion: @escaping (NSDictionary) -> Void) {
        let object: NSObject = client
        let callback: @convention(block) (NSDictionary) -> Void = completion
        object.perform(NSSelectorFromString("linkmeLifecycleRead:completion:"), with: args, with: callback)
    }

    func testLifecycleObjectiveCSelectorsValidateBeforeMutationAndReplayControlOnce() {
        let (client, transport) = makeControlledClient()
        let version = client.perform(NSSelectorFromString("linkmeLifecycleVersion"))!.takeUnretainedValue() as! NSNumber
        XCTAssertEqual(version.intValue, 1)
        let configure = lifecycleArgs("configure")
        XCTAssertEqual(lifecycleCall(client, configure)["ok"] as? Bool, true)
        let started = expectation(description: "owned HTTP started")
        transport.setOnStart { _, _ in started.fulfill() }
        let completed = expectation(description: "read completed")
        lifecycleRead(client, lifecycleArgs("claimDeferredIfAvailable")) { frame in
            XCTAssertEqual(frame["ok"] as? Bool, true)
            XCTAssertEqual(frame["ownerId"] as? String, "owner-a")
            XCTAssertEqual(frame["clientGeneration"] as? Int, 1)
            XCTAssertEqual((frame["payload"] as? NSDictionary)?["path"] as? String, "/owned")
            completed.fulfill()
        }
        wait(for: [started], timeout: 1)
        XCTAssertEqual(transport.operations[0].request.timeoutInterval, 0.75)
        XCTAssertEqual(lifecycleCall(client, configure)["duplicate"] as? Bool, true)
        XCTAssertEqual(transport.operations[0].task.cancelCount, 0)
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("configure", extra: ["appId": "changed"]))["error"] as? String, "generation_conflict")
        for invalid in [0, -1, 1.5, "15"] as [Any] {
            XCTAssertEqual(lifecycleCall(client, lifecycleArgs("configure", generation: 2, extra: ["requestTimeoutMs": invalid]))["error"] as? String, "invalid_args")
        }
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("configure", generation: 2, extra: ["sendDeviceInfo": "false"]))["error"] as? String, "invalid_args")
        transport.reply(0, body: #"{"path":"/owned"}"#)
        wait(for: [completed], timeout: 1)
    }

    func testLifecycleFramesStampOwnerAndGenerationAtPublicationAndRemovalIsIdempotent() {
        let (client, _) = makeControlledClient()
        let first = expectation(description: "first frame")
        let second = expectation(description: "second frame")
        var frames: [NSDictionary] = []
        let callback: @convention(block) (NSDictionary) -> Void = { frame in
            frames.append(frame)
            if frames.count == 1 { first.fulfill() } else if frames.count == 2 { second.fulfill() }
            else { XCTFail("Removed or unowned listener fired") }
        }
        let token = client.perform(NSSelectorFromString("linkmeLifecycleListen:"), with: callback)!.takeUnretainedValue() as! NSString
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("configure"))["ok"] as? Bool, true)
        client._debugEmit(LinkPayload(path: "/first", claimId: "receipt", claimMethod: "direct_cid", navigationAllowed: true))
        wait(for: [first], timeout: 1)
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("cancelPendingRequests", generation: 2))["ok"] as? Bool, true)
        client._debugEmit(LinkPayload(path: "/second"))
        wait(for: [second], timeout: 1)
        XCTAssertEqual(frames[0]["clientGeneration"] as? Int, 1)
        XCTAssertEqual(frames[1]["clientGeneration"] as? Int, 2)
        XCTAssertEqual(frames[0]["ownerId"] as? String, "owner-a")
        XCTAssertEqual((frames[0]["payload"] as? NSDictionary)?["claimId"] as? String, "receipt")
        client.perform(NSSelectorFromString("linkmeLifecycleUnlisten:"), with: token)
        client.perform(NSSelectorFromString("linkmeLifecycleUnlisten:"), with: token)
        client._debugEmit(LinkPayload(path: "/removed"))
        let barrier = expectation(description: "delivery drained")
        client.getInitialLink { _ in barrier.fulfill() }
        wait(for: [barrier], timeout: 1)
        XCTAssertEqual(frames.count, 2)
    }

    func testLifecycleCancellationDropsOldReadAndDuplicateCancelDoesNotCancelNewWork() {
        let (client, transport) = makeControlledClient()
        _ = lifecycleCall(client, lifecycleArgs("configure"))
        var started = expectation(description: "old request")
        transport.setOnStart { _, _ in started.fulfill() }
        let old = expectation(description: "old response withheld")
        lifecycleRead(client, lifecycleArgs("claimDeferredIfAvailable")) { frame in
            XCTAssertEqual(frame["error"] as? String, "owner_changed")
            XCTAssertNil(frame["payload"])
            old.fulfill()
        }
        wait(for: [started], timeout: 1)
        let cancel = lifecycleArgs("cancelPendingRequests", generation: 2)
        XCTAssertEqual(lifecycleCall(client, cancel)["ok"] as? Bool, true)
        wait(for: [old], timeout: 1)
        XCTAssertEqual(transport.operations[0].task.cancelCount, 1)
        transport.reply(0, body: #"{"path":"/late"}"#)
        started = expectation(description: "new request")
        let fresh = expectation(description: "fresh response")
        lifecycleRead(client, lifecycleArgs("claimDeferredIfAvailable", generation: 2)) { frame in
            XCTAssertEqual(frame["ok"] as? Bool, true)
            XCTAssertEqual(frame["ownerId"] as? String, "owner-a")
            XCTAssertEqual(frame["clientGeneration"] as? Int, 2)
            let payload = frame["payload"] as? NSDictionary
            XCTAssertEqual(payload?["path"] as? String, "/fresh")
            XCTAssertNil(payload?["ownerId"])
            fresh.fulfill()
        }
        wait(for: [started], timeout: 1)
        XCTAssertEqual(lifecycleCall(client, cancel)["duplicate"] as? Bool, true)
        XCTAssertEqual(transport.operations[1].task.cancelCount, 0)
        transport.reply(1, body: #"{"path":"/fresh","ownerId":"attacker","clientGeneration":999}"#)
        wait(for: [fresh], timeout: 1)
    }

    func testLifecycleOwnershipConflictsStaleCommandsAndDisposeReplayCannotRestoreOldContext() {
        let (client, _) = makeControlledClient()
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("configure"))["ok"] as? Bool, true)
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("configure", owner: "owner-b"))["error"] as? String, "owner_conflict")
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("cancelPendingRequests", owner: "owner-b", generation: 2))["error"] as? String, "owner_changed")
        let foreign = expectation(description: "foreign read denied")
        lifecycleRead(client, lifecycleArgs("getInitialLink", owner: "owner-b")) { frame in
            XCTAssertEqual(frame["error"] as? String, "owner_changed"); XCTAssertNil(frame["payload"]); foreign.fulfill()
        }
        wait(for: [foreign], timeout: 1)
        let identity = lifecycleArgs("setUserId", generation: 2, extra: ["userId": "user-a"])
        XCTAssertEqual(lifecycleCall(client, identity)["ok"] as? Bool, true)
        XCTAssertEqual(lifecycleCall(client, identity)["duplicate"] as? Bool, true)
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("setUserId", generation: 2, extra: ["userId": "user-b"]))["error"] as? String, "generation_conflict")
        let disposal = lifecycleArgs("dispose", generation: 3)
        XCTAssertEqual(lifecycleCall(client, disposal)["ok"] as? Bool, true)
        XCTAssertEqual(lifecycleCall(client, disposal)["duplicate"] as? Bool, true)
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("configure", generation: 1))["error"] as? String, "stale_generation")
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("configure", owner: "owner-b"))["ok"] as? Bool, true)
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("dispose", owner: "owner-b", generation: 2))["ok"] as? Bool, true)
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("configure", generation: 2))["error"] as? String, "stale_generation")
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("configure", generation: 4))["ok"] as? Bool, true)
    }

    func testLifecycleHeaderValidationAndDirectNativeControlWithdrawsWrapperOwnership() {
        let (client, _) = makeControlledClient()
        for fields: [String: Any] in [["contractVersion": true], ["clientGeneration": true], ["clientGeneration": 1.5], ["clientGeneration": -1], ["ownerId": ""], ["ownerId": String(repeating: "x", count: 129)]] {
            XCTAssertEqual(lifecycleCall(client, lifecycleArgs("configure", extra: fields))["error"] as? String, "invalid_args")
        }
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("configure"))["ok"] as? Bool, true)
        client.setUserId("native-host-user")
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("track", extra: ["event": "old-owner"]))["error"] as? String, "owner_changed")
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("configure", generation: 2))["ok"] as? Bool, true)
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("setUserId", generation: 3, extra: ["userId": " "]))["error"] as? String, "invalid_args")
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("setAdvertisingConsent", generation: 3, extra: ["granted": 1]))["error"] as? String, "invalid_args")
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("setAdvertisingConsent", generation: 3, extra: ["granted": false]))["ok"] as? Bool, true)
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("setReady", generation: 3))["ok"] as? Bool, true)
        XCTAssertEqual(lifecycleCall(client, lifecycleArgs("track", generation: 2, extra: ["event": "stale"]))["error"] as? String, "stale_generation")
    }

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}
