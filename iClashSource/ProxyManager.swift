import Foundation
import os.log

/// 代理管理器 - 负责代理列表缓存和选择逻辑
@MainActor
final class ProxyManager {
    static let shared = ProxyManager()

    private let logger = Logger(subsystem: "com.iclash.macos", category: "ProxyManager")

    private(set) var proxyGroups: [(name: String, proxies: [String])] = []
    private(set) var currentSelections: [String: String] = [:]

    private var isLoading = false
    private var lastRefreshTime: Date?
    private let cacheValidDuration: TimeInterval = 2.0

    private let mihomoService = MihomoService.shared
    private let configManager = ConfigManager.shared

    private init() {}

    /// 刷新代理列表（不自动启动内核）
    func refreshProxyList() async {
        guard mihomoService.isRunning else {
            return
        }

        if isLoading {
            return
        }

        if let lastTime = lastRefreshTime,
           Date().timeIntervalSince(lastTime) < cacheValidDuration,
           !proxyGroups.isEmpty {
            return
        }

        isLoading = true

        do {
            let proxies = try await mihomoService.fetchProxies()
            let configGroups = configManager.parseProxyGroupsOrder()
            var groups: [(name: String, proxies: [String])] = []
            var selections: [String: String] = [:]

            for (groupName, configProxies) in configGroups {
                if let info = proxies[groupName] {
                    groups.append((name: groupName, proxies: configProxies))
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
    }

    /// 选择代理
    func selectProxy(name: String, in group: String) async throws {
        try await mihomoService.selectProxy(name: name, in: group)
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
}
