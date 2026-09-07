import XCTest
@testable import LinkMeKit

final class LinkMeKitTests: XCTestCase {
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
}
