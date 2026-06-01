import XCTest
@testable import iClash

@MainActor
final class KernelUpdateCoordinatorTests: XCTestCase {
    func testPrepareFailureDoesNotStopRunningService() async {
        let service = FakeKernelService(isRunning: true, proxyEnabled: true)
        let state = AppState()
        let coordinator = AppCoordinator(mihomo: service, config: FakeConfigManager(), proxy: FakeProxyManager(), settings: FakeAppSettings(), appState: state)

        let result = await coordinator.updateKernel()

        guard case .failed = result else {
            return XCTFail("Expected failure result, got \(result)")
        }
        XCTAssertEqual(service.stopCallCount, 0)
        XCTAssertEqual(service.startCallCount, 0)
        XCTAssertEqual(service.proxyEnableRequests, [])
    }

    func testInstallFailureRestartsPreviouslyRunningServiceAndRestoresProxy() async {
        let service = FakeKernelService(isRunning: true, proxyEnabled: true)
        let state = AppState()
        let coordinator = AppCoordinator(mihomo: service, config: FakeConfigManager(), proxy: FakeProxyManager(), settings: FakeAppSettings(), appState: state)

        let result = await coordinator.updateKernel()

        guard case .failed = result else {
            return XCTFail("Expected failure result, got \(result)")
        }
        XCTAssertEqual(service.stopCallCount, 1)
        XCTAssertEqual(service.startCallCount, 1)
        // Should attempt to restore proxy since kernel was running
        XCTAssertTrue(service.proxyEnableRequests.contains(true))
    }
}
