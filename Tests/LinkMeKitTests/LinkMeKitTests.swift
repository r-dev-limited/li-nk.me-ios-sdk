import XCTest
@testable import LinkMeKit

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data?))?
    static var onStart: ((URLRequest) -> Void)?
    static var responseDelay: TimeInterval = 0

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
            self.client?.urlProtocolDidFinishLoading(self)
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
        pendingWork?.cancel()
        pendingWork = nil
    }
}

final class LinkMeKitTests: XCTestCase {
    private let baseURL = URL(string: "https://edge.example.test")!

    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.onStart = nil
        StubURLProtocol.responseDelay = 0
        super.tearDown()
    }

    private func makeClient(timeout: TimeInterval = 15) -> LinkMe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return LinkMe(
            urlSession: URLSession(configuration: configuration),
            requestTimeout: timeout
        )
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
    }

    func testListenerRemovalIsIdempotentAndIndependent() {
        let first = expectation(description: "first listener")
        let second = expectation(description: "second listener")
        let removeFirst = LinkMe.shared.addListener { _ in first.fulfill() }
        let removeSecond = LinkMe.shared.addListener { _ in second.fulfill() }

        LinkMe.shared._debugEmit(LinkPayload(path: "/one"))
        wait(for: [first, second], timeout: 1)
        removeFirst()
        removeFirst()
        removeSecond()
        removeSecond()
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
        XCTAssertTrue(LinkMe.shared.handle(url: URL(string: "myapp://welcome?cid=abc12345")!))
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
