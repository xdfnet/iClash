import Foundation
import os.log

/// 代理管理器 - 负责代理列表缓存和选择逻辑
///
/// 依赖通过构造器注入（便于测试替换）：
/// - `mihomo`: 内核进程服务（MihomoServiceProtocol）
/// - `config`: 配置管理器（ConfigManagerProtocol）
@MainActor
final class ProxyManager: ProxyManagerProtocol {
    static let shared = ProxyManager()

    private let logger = Logger(subsystem: "com.iclash.macos", category: "ProxyManager")

    private(set) var proxyGroups: [(name: String, proxies: [String])] = []
    private(set) var currentSelections: [String: String] = [:]

    private var isLoading = false
    private var lastRefreshTime: Date?
    private let cacheValidDuration: TimeInterval = 2.0

    private let mihomo: any MihomoServiceProtocol
    private let config: any ConfigManagerProtocol

    weak var delegate: ProxyManagerDelegate?

    init(mihomo: any MihomoServiceProtocol = MihomoService.shared,
         config: any ConfigManagerProtocol = ConfigManager.shared) {
        self.mihomo = mihomo
        self.config = config
    }

    /// 刷新代理列表（不自动启动内核），完成后通知 delegate
    func refreshProxyList() async {
        guard mihomo.isRunning else { return }
        if isLoading { return }
        if let lastTime = lastRefreshTime,
           Date().timeIntervalSince(lastTime) < cacheValidDuration,
           !proxyGroups.isEmpty { return }

        isLoading = true

        do {
            let proxies = try await mihomo.fetchProxies()
            let groupOrder = config.parseProxyGroupsOrder()
            var groups: [(name: String, proxies: [String])] = []
            var selections: [String: String] = [:]

            for groupName in groupOrder {
                if let info = proxies[groupName] {
                    let proxyList = info.all ?? []
                    groups.append((name: groupName, proxies: proxyList))
                    if let now = info.now {
                        selections[groupName] = now
                    }
                }
            }

            proxyGroups = groups
            currentSelections = selections
            lastRefreshTime = Date()
        } catch {
            logger.error("Failed to load proxy list: \(error.localizedDescription, privacy: .public)")
        }

        isLoading = false
        delegate?.proxyManagerDidRefresh(self)
    }

    /// 选择代理
    func selectProxy(name: String, in group: String) async throws {
        try await mihomo.selectProxy(name: name, in: group)
        currentSelections[group] = name
    }

    /// 获取当前选中的代理
    func currentSelection(for group: String) -> String? {
        currentSelections[group]
    }

    /// 检查是否正在加载
    var isLoadingProxies: Bool {
        isLoading
    }

    /// 清空缓存的代理状态
    func reset() {
        proxyGroups = []
        currentSelections = [:]
        lastRefreshTime = nil
        isLoading = false
    }
}

// MARK: - Delegate

/// 当代理列表刷新完成时通知（用于触发菜单重建）
@MainActor
protocol ProxyManagerDelegate: AnyObject {
    func proxyManagerDidRefresh(_ manager: ProxyManager)
}
