import XCTest
@testable import iClash

@MainActor
final class AppSettingsTests: XCTestCase {
    private let settings = AppSettings.shared

    override func setUp() {
        super.setUp()
        settings.subscriptionURL = ""
    }

    override func tearDown() {
        settings.subscriptionURL = ""
        super.tearDown()
    }

    func testSubscriptionURL_roundTrips() {
        settings.subscriptionURL = "https://example.com/subscription"
        XCTAssertEqual(settings.subscriptionURL, "https://example.com/subscription")
    }

    func testSubscriptionURL_setAndGet() {
        settings.subscriptionURL = "  https://example.com/subscription  "
        XCTAssertEqual(settings.subscriptionURL, "https://example.com/subscription")
    }

    func testHasSubscriptionURL_detectsEmpty() {
        settings.subscriptionURL = ""
        XCTAssertFalse(settings.hasSubscriptionURL)
    }

    func testHasSubscriptionURL_detectsNonEmpty() {
        settings.subscriptionURL = "https://example.com/subscription"
        XCTAssertTrue(settings.hasSubscriptionURL)
    }

    func testHasSubscriptionURL_detectsWhitespaceOnly() {
        settings.subscriptionURL = "   "
        XCTAssertFalse(settings.hasSubscriptionURL)
    }

}