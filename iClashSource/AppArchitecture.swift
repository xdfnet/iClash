import Foundation
import Observation
import os.log

// MARK: - AppState

/// 应用全局状态 — 唯一真相来源（Single Source of Truth）
@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    // MARK: 内核状态
    var isRunning = false
    var isProxyEnabled = false
    var kernelVersion = "未知"

    // MARK: 代理组/节点
    var proxyGroups: [(name: String, proxies: [String])] = []
    var currentSelections: [String: String] = [:]
    var isLoadingProxies = false

    // MARK: 错误
    var lastError: String? {
        didSet { if lastError != nil { errorCount += 1 } }
    }
    private(set) var errorCount = 0

    // MARK: 订阅
    var hasSubscriptionURL = false

    init() {}

    /// 从 MihomoService + ProxyManager 同步完整状态
    func syncFromServices(mihomo: any MihomoServiceProtocol, proxy: any ProxyManagerProtocol) {
        isRunning = mihomo.isRunning
        isProxyEnabled = mihomo.isSystemProxyEnabled()
        kernelVersion = mihomo.kernelVersion.isEmpty ? "未知" : mihomo.kernelVersion
        proxyGroups = proxy.proxyGroups
        currentSelections = proxy.currentSelections
        isLoadingProxies = proxy.isLoadingProxies
    }

    /// 重置运行时状态（订阅变更 / 停止服务时）
    func resetRuntime() {
        isRunning = false
        isProxyEnabled = false
        kernelVersion = "未知"
        proxyGroups = []
        currentSelections = [:]
        isLoadingProxies = false
    }
}

// MARK: - AppCoordinator

/// 应用协调器 — 统一编排所有服务的启动/停止/切换/更新流程
@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()

    private let mihomo: any MihomoServiceProtocol
    private let config: any ConfigManagerProtocol
    private let proxy: any ProxyManagerProtocol
    private let settings: any AppSettingsProtocol
    private let appState: AppState
    private let logger = Logger(subsystem: "com.iclash.macos", category: "AppCoordinator")

    /// 尝试执行系统代理操作，失败时记录日志（非致命，继续流程）
    private func safelySetProxy(enabled: Bool) {
        do {
            try mihomo.setSystemProxy(enabled: enabled)
        } catch {
            logger.warning("设置系统代理失败 (enabled=\(enabled)): \(error.localizedDescription, privacy: .public)")
        }
    }

    init(
        mihomo: any MihomoServiceProtocol = MihomoService.shared,
        config: any ConfigManagerProtocol = ConfigManager.shared,
        proxy: any ProxyManagerProtocol = ProxyManager.shared,
        settings: any AppSettingsProtocol = AppSettings.shared,
        appState: AppState = .shared
    ) {
        self.mihomo = mihomo
        self.config = config
        self.proxy = proxy
        self.settings = settings
        self.appState = appState
    }

    // MARK: - 生命周期

    /// 开机自动启动（无订阅时只显示菜单栏图标）
    func autoStart() async {
        appState.hasSubscriptionURL = settings.hasSubscriptionURL
        guard settings.hasSubscriptionURL else {
            appState.resetRuntime()
            return
        }
        await applySubscription(url: settings.subscriptionURL)
    }

    /// 订阅变更：停止旧服务 → 下载新配置 → 启动内核 → 恢复代理
    func applySubscription(url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            await clearSubscription()
            return
        }

        let proxyWasEnabled = mihomo.isSystemProxyEnabled()
        await stopServices(clearProxyState: proxyWasEnabled)

        do {
            logger.info("Downloading subscription...")
            _ = try await config.downloadAndValidateConfig(url: trimmed)

            logger.info("Starting mihomo kernel...")
            try await mihomo.start()

            if proxyWasEnabled {
                safelySetProxy(enabled: true)
            }

            async let fetchVersion: Void = mihomo.fetchKernelVersion()
            async let refreshProxies: Void = proxy.refreshProxyList()
            _ = await (fetchVersion, refreshProxies)

            appState.syncFromServices(mihomo: mihomo, proxy: proxy)
            logger.info("Service started successfully")
        } catch {
            logger.error("Failed to start: \(error.localizedDescription, privacy: .public)")
            appState.resetRuntime()
            appState.lastError = "启动失败: \(error.localizedDescription)"
        }
    }

    private func clearSubscription() async {
        if mihomo.isSystemProxyEnabled() {
            safelySetProxy(enabled: false)
        }
        await stopServices(clearProxyState: false)
        appState.resetRuntime()
        settings.subscriptionURL = ""
    }

    private func stopServices(clearProxyState: Bool) async {
        if clearProxyState {
            safelySetProxy(enabled: false)
        }
        if mihomo.isRunning {
            mihomo.stop()
        }
        proxy.reset()
    }

    // MARK: - 代理控制

    func toggleProxy() {
        guard settings.hasSubscriptionURL else {
            appState.lastError = "请先配置订阅地址"
            return
        }
        if appState.isProxyEnabled {
            safelySetProxy(enabled: false)
        } else {
            safelySetProxy(enabled: true)
        }
        appState.isProxyEnabled = mihomo.isSystemProxyEnabled()
    }

    func selectProxy(name: String, in group: String) async {
        do {
            try await proxy.selectProxy(name: name, in: group)
            appState.currentSelections = proxy.currentSelections
        } catch {
            appState.lastError = "切换节点失败: \(error.localizedDescription)"
        }
    }

    func refreshProxies() async {
        guard mihomo.isRunning else { return }
        await proxy.refreshProxyList()
        appState.proxyGroups = proxy.proxyGroups
        appState.currentSelections = proxy.currentSelections
        appState.isLoadingProxies = proxy.isLoadingProxies
    }

    // MARK: - 内核更新

    func updateKernel() async -> KernelUpdateFlowResult {
        let wasRunning = mihomo.isRunning
        let wasProxyEnabled = mihomo.isSystemProxyEnabled()
        let result = await KernelUpdater.shared.updateKernel()

        switch result {
        case .alreadyLatest:
            return .alreadyLatest

        case .failed(let error):
            appState.lastError = "内核更新失败: \(error.localizedDescription)"
            return .failed(error)

        case .ready(let newVersion, let downloadedPath):
            do {
                if wasRunning {
                    mihomo.stop()
                }
                try KernelUpdater.shared.installKernel(from: downloadedPath)
                mihomo.updateKernelVersion(newVersion)

                if wasRunning {
                    try await mihomo.start()
                    if wasProxyEnabled {
                        try mihomo.setSystemProxy(enabled: true)
                    }
                    await mihomo.fetchKernelVersion()
                }

                appState.syncFromServices(mihomo: mihomo, proxy: proxy)
                return .updated(version: newVersion, restarted: wasRunning)
            } catch {
                KernelUpdater.shared.cleanupTemporaryDownload()
                if wasRunning {
                    try? await mihomo.start()
                    if wasProxyEnabled {
                        safelySetProxy(enabled: true)
                    }
                }
                appState.lastError = "内核更新失败: \(error.localizedDescription)"
                return .failed(error)
            }
        }
    }

    func fetchLatestVersion() async -> String {
        (try? await KernelUpdater.shared.checkForUpdate()) ?? "获取失败"
    }

    // MARK: - 退出

    func prepareForQuit() {
        if mihomo.isRunning {
            safelySetProxy(enabled: false)
            mihomo.stop()
        }
        proxy.reset()
    }
}
