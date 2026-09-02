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
        // nothing to assert yet; just ensure compiles/links
        XCTAssertTrue(true)
    }
}

