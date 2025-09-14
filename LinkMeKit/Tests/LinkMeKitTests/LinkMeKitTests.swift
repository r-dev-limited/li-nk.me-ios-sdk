import XCTest
@testable import LinkMeKit

final class LinkMeKitTests: XCTestCase {
    func testInit() {
        let url = URL(string: "https://li-nk.me")!
        LinkMe.shared.`init`(config: .init(baseUrl: url))
        // nothing to assert yet; just ensure compiles/links
        XCTAssertTrue(true)
    }
}

