import XCTest
@testable import iClash

@MainActor
final class MenuControllerTests: XCTestCase {
    private var fakeDelegate: FakeMenuControllerDelegate!
    private var menuController: MenuController!

    override func setUp() {
        super.setUp()
        fakeDelegate = FakeMenuControllerDelegate()
        let state = AppState()
        let coordinator = AppCoordinator(mihomo: FakeKernelService(isRunning: false, proxyEnabled: false), config: FakeConfigManager(), proxy: FakeProxyManager(), settings: FakeAppSettings(), appState: state)
        menuController = MenuController(delegate: fakeDelegate, coordinator: coordinator, appState: state)
    }

    func testBuildMenu_createsAllItems() {
        let menu = menuController.buildMenu()

        XCTAssertEqual(menu.items.count, 9)

        let titles = menu.items.compactMap { $0.title }
        XCTAssertTrue(titles.contains("启动代理"))
        XCTAssertTrue(titles.contains("切换节点"))
        XCTAssertTrue(titles.contains("订阅设置"))
        XCTAssertTrue(titles.contains("软件版本"))
        XCTAssertTrue(titles.contains("退出"))
    }

    func testBuildMenu_includesProxyToggleItem() {
        let menu = menuController.buildMenu()

        let toggleItem = menu.items.first
        XCTAssertNotNil(toggleItem)
        XCTAssertTrue(toggleItem?.title == "启动代理" || toggleItem?.title == "停止代理")
        XCTAssertNotNil(toggleItem?.target)
    }

    func testBuildMenu_includesSwitchNodeItem() {
        let menu = menuController.buildMenu()

        let switchItem = menu.items.first { $0.title == "切换节点" }
        XCTAssertNotNil(switchItem)
        XCTAssertNotNil(switchItem?.submenu)
    }

    func testBuildMenu_includesSettingsItem() {
        let menu = menuController.buildMenu()

        let settingsItem = menu.items.first { $0.title == "订阅设置" }
        XCTAssertNotNil(settingsItem)
        XCTAssertNotNil(settingsItem?.target)
    }

    func testBuildMenu_includesVersionItem() {
        let menu = menuController.buildMenu()

        let versionItem = menu.items.first { $0.title == "软件版本" }
        XCTAssertNotNil(versionItem)
        XCTAssertNotNil(versionItem?.target)
    }

    func testBuildMenu_includesQuitItem() {
        let menu = menuController.buildMenu()

        let quitItem = menu.items.first { $0.title == "退出" }
        XCTAssertNotNil(quitItem)
    }

    func testBuildMenu_setsMenuDelegate() {
        let menu = menuController.buildMenu()

        XCTAssertEqual(menu.delegate as? MenuController, menuController)
    }

    func testMenuWillOpen_callsDelegate() {
        let menu = menuController.buildMenu()

        if let delegate = menu.delegate as? MenuController {
            delegate.menuWillOpen(menu)
            XCTAssertEqual(fakeDelegate.menuWillOpenCallCount, 1)
        } else {
            XCTFail("Menu delegate is not MenuController")
        }
    }
}

@MainActor
private final class FakeMenuControllerDelegate: MenuControllerDelegate {
    var menuWillOpenCallCount = 0
    var selectProxyCallCount = 0
    var toggleProxyCallCount = 0
    var openSettingsCallCount = 0
    var updateKernelCallCount = 0
    var quitAppCallCount = 0
    var lastSelectedProxy: (name: String, group: String)?

    func reset() {
        menuWillOpenCallCount = 0
        selectProxyCallCount = 0
        toggleProxyCallCount = 0
        openSettingsCallCount = 0
        updateKernelCallCount = 0
        quitAppCallCount = 0
        lastSelectedProxy = nil
    }

    func menuWillOpen() {
        menuWillOpenCallCount += 1
    }

    func selectProxy(name: String, in group: String) {
        selectProxyCallCount += 1
        lastSelectedProxy = (name, group)
    }

    func toggleProxy() {
        toggleProxyCallCount += 1
    }

    func openSettings() {
        openSettingsCallCount += 1
    }

    func updateKernel() {
        updateKernelCallCount += 1
    }

    func quitApp() {
        quitAppCallCount += 1
    }

    func fetchLatestVersion() async -> String {
        return "v1.19.26"
    }

    func canOfferUpdate() async -> Bool {
        return false
    }
}