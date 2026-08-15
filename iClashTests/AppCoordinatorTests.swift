import XCTest
@testable import iClash

/// AppCoordinator 生命周期与代理开关的回归测试
@MainActor
final class AppCoordinatorTests: XCTestCase {

    private func makeCoordinator(
        isRunning: Bool,
        proxyEnabled: Bool,
        subscriptionURL: String = "https://example.com/sub",
        startError: Error? = nil
    ) -> (coordinator: AppCoordinator, kernel: FakeKernelService, state: AppState, settings: FakeAppSettings) {
        let kernel = FakeKernelService(isRunning: isRunning, proxyEnabled: proxyEnabled)
        kernel.startError = startError
        let state = AppState()
        let settings = FakeAppSettings()
        settings.subscriptionURL = subscriptionURL
        let coordinator = AppCoordinator(
            mihomo: kernel,
            config: FakeConfigManager(),
            proxy: FakeProxyManager(),
            settings: settings,
            appState: state
        )
        return (coordinator, kernel, state, settings)
    }

    // MARK: - toggleProxy

    func testToggleProxy_enablesSystemProxy_whenKernelRunning() async {
        let (coordinator, kernel, state, _) = makeCoordinator(isRunning: true, proxyEnabled: false)

        await coordinator.toggleProxy()

        XCTAssertEqual(kernel.proxyEnableRequests, [true])
        XCTAssertTrue(state.isProxyEnabled)
        XCTAssertNil(state.lastError)
    }

    func testToggleProxy_startsKernelFirst_whenKernelNotRunning() async {
        let (coordinator, kernel, state, _) = makeCoordinator(isRunning: false, proxyEnabled: false)

        await coordinator.toggleProxy()

        XCTAssertEqual(kernel.startCallCount, 1)
        XCTAssertEqual(kernel.proxyEnableRequests, [true])
        XCTAssertTrue(kernel.isRunning)
        XCTAssertTrue(state.isProxyEnabled)
    }

    func testToggleProxy_rollsBack_whenKernelStartFails() async {
        let (coordinator, kernel, state, _) = makeCoordinator(
            isRunning: false,
            proxyEnabled: false,
            startError: FakeError.prepareFailed
        )

        await coordinator.toggleProxy()

        XCTAssertEqual(kernel.startCallCount, 1)
        XCTAssertTrue(kernel.proxyEnableRequests.isEmpty, "内核启动失败时不应开启系统代理")
        XCTAssertFalse(state.isProxyEnabled)
        XCTAssertNotNil(state.lastError)
    }

    func testToggleProxy_disablesSystemProxy() async {
        let (coordinator, kernel, state, _) = makeCoordinator(isRunning: true, proxyEnabled: true)
        state.isProxyEnabled = true // 模拟菜单打开时同步到的真实系统状态

        await coordinator.toggleProxy()

        XCTAssertEqual(kernel.proxyEnableRequests, [false])
        XCTAssertFalse(state.isProxyEnabled)
    }

    func testToggleProxy_withoutSubscription_doesNotTouchProxy() async {
        let (coordinator, kernel, state, settings) = makeCoordinator(isRunning: true, proxyEnabled: false)
        settings.subscriptionURL = ""

        await coordinator.toggleProxy()

        XCTAssertTrue(kernel.proxyEnableRequests.isEmpty)
        XCTAssertEqual(state.lastError, "请先配置订阅地址")
    }

    // MARK: - prepareForQuit

    func testPrepareForQuit_clearsSystemProxyAndStopsKernel() {
        let (coordinator, kernel, _, _) = makeCoordinator(isRunning: true, proxyEnabled: true)

        coordinator.prepareForQuit()

        XCTAssertEqual(kernel.proxyEnableRequests, [false])
        XCTAssertEqual(kernel.stopCallCount, 1)
        XCTAssertFalse(kernel.isRunning)
    }

    func testPrepareForQuit_doesNotTouchProxyWhenNotEnabled() {
        let (coordinator, kernel, _, _) = makeCoordinator(isRunning: true, proxyEnabled: false)

        coordinator.prepareForQuit()

        XCTAssertTrue(kernel.proxyEnableRequests.isEmpty)
        XCTAssertEqual(kernel.stopCallCount, 1)
        XCTAssertFalse(kernel.isRunning)
    }
}
