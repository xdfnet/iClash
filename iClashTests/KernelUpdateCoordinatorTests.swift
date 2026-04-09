import XCTest
@testable import iClash

@MainActor
final class KernelUpdateCoordinatorTests: XCTestCase {
    func testPrepareFailureDoesNotStopRunningService() async {
        let service = FakeKernelService(isRunning: true, proxyEnabled: true)
        let updater = FakeKernelUpdater(result: .failed(FakeError.prepareFailed))
        let coordinator = KernelUpdateCoordinator(service: service, updater: updater)

        let result = await coordinator.performUpdate()

        guard case .failed = result else {
            return XCTFail("Expected failure result")
        }
        XCTAssertEqual(service.stopCallCount, 0)
        XCTAssertEqual(service.startCallCount, 0)
        XCTAssertEqual(service.proxyEnableRequests, [])
        XCTAssertEqual(updater.installCallCount, 0)
    }

    func testInstallFailureRestartsPreviouslyRunningServiceAndRestoresProxy() async {
        let service = FakeKernelService(isRunning: true, proxyEnabled: true)
        let updater = FakeKernelUpdater(
            result: .ready(newVersion: "v1.19.1", downloadedPath: URL(fileURLWithPath: "/tmp/mihomo")),
            installError: FakeError.installFailed
        )
        let coordinator = KernelUpdateCoordinator(service: service, updater: updater)

        let result = await coordinator.performUpdate()

        guard case .failed(let error) = result else {
            return XCTFail("Expected failure result")
        }
        XCTAssertEqual(error as? FakeError, .installFailed)
        XCTAssertEqual(service.stopCallCount, 1)
        XCTAssertEqual(service.startCallCount, 1)
        XCTAssertEqual(service.proxyEnableRequests, [true])
        XCTAssertEqual(updater.installCallCount, 1)
        XCTAssertEqual(updater.cleanupCallCount, 1)
    }
}

@MainActor
private final class FakeKernelService: KernelServiceControlling {
    var isRunning: Bool
    private let proxyEnabled: Bool

    private(set) var stopCallCount = 0
    private(set) var startCallCount = 0
    private(set) var proxyEnableRequests: [Bool] = []
    private(set) var updatedVersions: [String] = []
    private(set) var fetchVersionCallCount = 0

    init(isRunning: Bool, proxyEnabled: Bool) {
        self.isRunning = isRunning
        self.proxyEnabled = proxyEnabled
    }

    func isSystemProxyEnabled() -> Bool {
        proxyEnabled
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
    }

    func start() async throws {
        startCallCount += 1
        isRunning = true
    }

    func setSystemProxy(enabled: Bool) throws {
        proxyEnableRequests.append(enabled)
    }

    func updateKernelVersion(_ version: String) {
        updatedVersions.append(version)
    }

    func fetchKernelVersion() async {
        fetchVersionCallCount += 1
    }
}

@MainActor
private final class FakeKernelUpdater: KernelUpdateManaging {
    let result: KernelUpdateResult
    let installError: Error?

    private(set) var installCallCount = 0
    private(set) var cleanupCallCount = 0

    init(result: KernelUpdateResult, installError: Error? = nil) {
        self.result = result
        self.installError = installError
    }

    func updateKernel() async -> KernelUpdateResult {
        result
    }

    func installKernel(from downloadedPath: URL) throws {
        installCallCount += 1
        if let installError {
            throw installError
        }
    }

    func cleanupTemporaryDownload() {
        cleanupCallCount += 1
    }
}

private enum FakeError: Error, Equatable {
    case prepareFailed
    case installFailed
}
