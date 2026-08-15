import Foundation
@testable import iClash

// MARK: - 测试替身（共享于多个测试文件）

@MainActor
final class FakeKernelService: MihomoServiceProtocol {
    var isRunning: Bool
    var kernelVersion: String = "v1.19.0"
    private(set) var proxyEnabled: Bool

    private(set) var stopCallCount = 0
    private(set) var startCallCount = 0
    private(set) var proxyEnableRequests: [Bool] = []
    private(set) var fetchVersionCallCount = 0

    /// 注入 start() 抛出的错误（模拟内核启动失败）
    var startError: Error?

    init(isRunning: Bool, proxyEnabled: Bool) {
        self.isRunning = isRunning
        self.proxyEnabled = proxyEnabled
    }

    func isSystemProxyEnabled() -> Bool { proxyEnabled }
    func stop() { stopCallCount += 1; isRunning = false }
    func start() async throws {
        startCallCount += 1
        if let startError { throw startError }
        isRunning = true
    }
    func setSystemProxy(enabled: Bool) throws {
        proxyEnableRequests.append(enabled)
        proxyEnabled = enabled
    }
    func fetchKernelVersion() async { fetchVersionCallCount += 1 }
    func fetchProxies() async throws -> [String: ProxyInfo] { [:] }
    func selectProxy(name: String, in group: String) async throws {}
}
final class FakeConfigManager: ConfigManagerProtocol {
    var configDirectory: URL { URL(fileURLWithPath: "/tmp/.config/iclash") }
    var runtimeConfigFile: URL { configDirectory.appendingPathComponent("config.yaml") }
    var runtimeConfigFileExists: Bool { true }
    func prepareRuntimeConfigFile() async throws -> URL { runtimeConfigFile }
    func downloadIfChanged(url: String, retryCount: Int) async throws -> Bool { true }
    func parseProxyGroupsOrder() -> [String] { [] }
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
}

enum FakeError: Error, Equatable {
    case prepareFailed
    case installFailed
}
