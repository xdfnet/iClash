import Foundation
@testable import iClash

// MARK: - 测试替身（共享于多个测试文件）

@MainActor
final class FakeKernelService: MihomoServiceProtocol {
    var isRunning: Bool
    var kernelVersion: String = "v1.19.0"
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

    func isSystemProxyEnabled() -> Bool { proxyEnabled }
    func stop() { stopCallCount += 1; isRunning = false }
    func start() async throws { startCallCount += 1; isRunning = true }
    func setSystemProxy(enabled: Bool) throws { proxyEnableRequests.append(enabled) }
    func updateKernelVersion(_ version: String) { updatedVersions.append(version) }
    func fetchKernelVersion() async { fetchVersionCallCount += 1 }
    func fetchProxies() async throws -> [String: ProxyInfo] { [:] }
    func selectProxy(name: String, in group: String) async throws {}
}

@MainActor
final class FakeKernelUpdater: KernelUpdateManaging {
    let result: KernelUpdateResult
    let installError: Error?
    private(set) var installCallCount = 0
    private(set) var cleanupCallCount = 0

    init(result: KernelUpdateResult, installError: Error? = nil) {
        self.result = result
        self.installError = installError
    }

    func updateKernel() async -> KernelUpdateResult { result }
    func installKernel(from downloadedPath: URL) throws {
        installCallCount += 1
        if let installError { throw installError }
    }
    func cleanupTemporaryDownload() { cleanupCallCount += 1 }
}

final class FakeConfigManager: ConfigManagerProtocol {
    var configDirectory: URL { URL(fileURLWithPath: "/tmp/.config/iclash") }
    var runtimeConfigFile: URL { configDirectory.appendingPathComponent("config.yaml") }
    var runtimeConfigFileExists: Bool { true }
    func ensureBaseConfigurationExists() throws {}
    func prepareRuntimeConfigFile() async throws -> URL { runtimeConfigFile }
    func downloadAndValidateConfig(url: String, retryCount: Int) async throws -> URL { runtimeConfigFile }
    func parseProxyGroupsOrder() -> [(name: String, proxies: [String])] { [] }
}

@MainActor
final class FakeProxyManager: ProxyManagerProtocol {
    var proxyGroups: [(name: String, proxies: [String])] = []
    var currentSelections: [String: String] = [:]
    var isLoadingProxies = false
    func refreshProxyList() async {}
    func selectProxy(name: String, in group: String) async throws {}
    func reset() { proxyGroups = []; currentSelections = [:] }
}

final class FakeAppSettings: AppSettingsProtocol {
    var subscriptionURL: String = ""
    var hasSubscriptionURL: Bool { !subscriptionURL.isEmpty }
    var lastUpdateTime: Date?
}

enum FakeError: Error, Equatable {
    case prepareFailed
    case installFailed
}
