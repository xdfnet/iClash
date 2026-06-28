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

    func prepareRuntimeConfigFile() async throws -> URL
    func downloadIfChanged(url: String, retryCount: Int) async throws -> Bool
    func parseProxyGroupsOrder() -> [String]
}

extension ConfigManagerProtocol {
    /// 提供默认 retryCount = 3
    func downloadIfChanged(url: String) async throws -> Bool {
        try await downloadIfChanged(url: url, retryCount: 3)
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
}

// MARK: - Kernel Service

@MainActor
protocol KernelServiceControlling: AnyObject {
    var isRunning: Bool { get }
    func isSystemProxyEnabled() -> Bool
    func stop()
    func start() async throws
    func setSystemProxy(enabled: Bool) throws
    func fetchKernelVersion() async
}

// MARK: - Conformances

extension MihomoService: MihomoServiceProtocol {}
extension ConfigManager: ConfigManagerProtocol {}
extension AppSettings: AppSettingsProtocol {}

// MARK: - 通知

extension Notification.Name {
    /// 内核进程意外退出时发送
    static let mihomoCrashed = Notification.Name("mihomoCrashed")
}
