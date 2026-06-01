import Foundation

// MARK: - MihomoService

protocol MihomoServiceProtocol: AnyObject, KernelServiceControlling {
    var kernelVersion: String { get }

    func fetchProxies() async throws -> [String: ProxyInfo]
    func selectProxy(name: String, in group: String) async throws
}

// MARK: - ConfigManager

protocol ConfigManagerProtocol {
    var configDirectory: URL { get }
    var runtimeConfigFile: URL { get }
    var runtimeConfigFileExists: Bool { get }

    func ensureBaseConfigurationExists() throws
    func prepareRuntimeConfigFile() async throws -> URL
    func downloadAndValidateConfig(url: String, retryCount: Int) async throws -> URL
    func parseProxyGroupsOrder() -> [(name: String, proxies: [String])]
}

extension ConfigManagerProtocol {
    /// 提供默认 retryCount = 3
    func downloadAndValidateConfig(url: String) async throws -> URL {
        try await downloadAndValidateConfig(url: url, retryCount: 3)
    }
}

// MARK: - ProxyManager

protocol ProxyManagerProtocol: AnyObject {
    var proxyGroups: [(name: String, proxies: [String])] { get }
    var currentSelections: [String: String] { get }
    var isLoadingProxies: Bool { get }

    func refreshProxyList() async
    func selectProxy(name: String, in group: String) async throws
    func reset()
}

// MARK: - AppSettings

protocol AppSettingsProtocol: AnyObject {
    var subscriptionURL: String { get set }
    var hasSubscriptionURL: Bool { get }
    var lastUpdateTime: Date? { get set }
}

// MARK: - Kernel Service (used by KernelUpdater)

@MainActor
protocol KernelServiceControlling: AnyObject {
    var isRunning: Bool { get }
    func isSystemProxyEnabled() -> Bool
    func stop()
    func start() async throws
    func setSystemProxy(enabled: Bool) throws
    func updateKernelVersion(_ version: String)
    func fetchKernelVersion() async
}

@MainActor
protocol KernelUpdateManaging: AnyObject {
    func updateKernel() async -> KernelUpdateResult
    func installKernel(from downloadedPath: URL) throws
    func cleanupTemporaryDownload()
}

// MARK: - 更新结果

enum KernelUpdateFlowResult {
    case alreadyLatest
    case updated(version: String, restarted: Bool)
    case failed(Error)
}

// MARK: - Conformances

extension MihomoService: MihomoServiceProtocol {}
extension MihomoService: KernelServiceControlling {}
extension KernelUpdater: KernelUpdateManaging {}
extension ConfigManager: ConfigManagerProtocol {}
extension ProxyManager: ProxyManagerProtocol {}
extension AppSettings: AppSettingsProtocol {}
