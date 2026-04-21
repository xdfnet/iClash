import XCTest
@testable import iClash

@MainActor
final class StatusBarControllerTests: XCTestCase {
    func testSetMenu_storesMenu() {
        let controller = StatusBarController()
        let menu = NSMenu()

        controller.setMenu(menu)

        XCTAssertNotNil(controller.getMenu())
        XCTAssertEqual(controller.getMenu(), menu)
    }

    func testGetMenu_returnsNilWhenNoMenuSet() {
        let controller = StatusBarController()

        XCTAssertNil(controller.getMenu())
    }
}