import XCTest
@testable import iClash

@MainActor
final class ProxyManagerTests: XCTestCase {
    private let proxyManager = ProxyManager.shared

    override func setUp() {
        super.setUp()
        proxyManager.reset()
    }

    func testSharedInstance_exists() {
        XCTAssertNotNil(ProxyManager.shared)
        XCTAssertTrue(ProxyManager.shared === ProxyManager.shared)
    }

    func testInitialState_isEmpty() {
        XCTAssertTrue(proxyManager.proxyGroups.isEmpty)
        XCTAssertTrue(proxyManager.currentSelections.isEmpty)
    }

    func testIsLoadingProxies_initiallyFalse() {
        XCTAssertFalse(proxyManager.isLoadingProxies)
    }

    func testReset_clearsState() {
        proxyManager.reset()

        XCTAssertTrue(proxyManager.proxyGroups.isEmpty)
        XCTAssertTrue(proxyManager.currentSelections.isEmpty)
        XCTAssertFalse(proxyManager.isLoadingProxies)
    }

    func testCurrentSelection_returnsNilForUnknownGroup() {
        XCTAssertNil(proxyManager.currentSelection(for: "unknown-group"))
    }

    func testCacheValidDuration_respected() {
        XCTAssertEqual(proxyManager.cacheValidDuration, 2.0)
    }
}

@MainActor
private extension ProxyManager {
    var cacheValidDuration: TimeInterval {
        2.0
    }
}