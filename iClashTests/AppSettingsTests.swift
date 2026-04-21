import XCTest
@testable import iClash

@MainActor
final class AppSettingsTests: XCTestCase {
    private let settings = AppSettings.shared

    override func setUp() {
        super.setUp()
        settings.resetToDefaults()
    }

    override func tearDown() {
        settings.resetToDefaults()
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

    func testLastUpdateTime_persists() {
        let testDate = Date(timeIntervalSince1970: 1704067200)
        settings.lastUpdateTime = testDate
        XCTAssertEqual(settings.lastUpdateTime, testDate)
    }

    func testLastUpdateTime_setAndGet() {
        let testDate = Date()
        settings.lastUpdateTime = testDate
        XCTAssertNotNil(settings.lastUpdateTime)
        XCTAssertEqual(settings.lastUpdateTime, testDate)
    }

    func testLastUpdateTime_canBeNil() {
        settings.lastUpdateTime = nil
        XCTAssertNil(settings.lastUpdateTime)
    }

    func testResetToDefaults_clearsAll() {
        settings.subscriptionURL = "https://example.com/subscription"
        settings.lastUpdateTime = Date()

        settings.resetToDefaults()

        XCTAssertEqual(settings.subscriptionURL, "")
        XCTAssertNil(settings.lastUpdateTime)
        XCTAssertFalse(settings.hasSubscriptionURL)
    }
}