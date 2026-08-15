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
    var lastError: String?

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

        DaemonLogger.shared.log("AUTO", "启动应用，订阅地址: \(settings.hasSubscriptionURL ? "已配置" : "未配置")")

        // 已有运行配置则直接启动内核，避免每次启动都重新下载
        if config.runtimeConfigFileExists {
            do {
                DaemonLogger.shared.log("AUTO", "config.yaml 已存在，直接启动内核")
                try await mihomo.start()
                async let fetchVersion: Void = mihomo.fetchKernelVersion()
                async let refreshProxies: Void = proxy.refreshProxyList()
                _ = await (fetchVersion, refreshProxies)
                appState.syncFromServices(mihomo: mihomo, proxy: proxy)
                DaemonLogger.shared.log("AUTO", "启动完成，内核版本: \(mihomo.kernelVersion)")
                return
            } catch {
                logger.warning("使用现有配置启动失败，将重新下载: \(error.localizedDescription, privacy: .public)")
                DaemonLogger.shared.log("AUTO", "使用现有配置启动失败: \(error.localizedDescription)")
            }
        }

        await applySubscription(url: settings.subscriptionURL)
    }

    /// 订阅变更：停止旧服务 → 下载新配置 → 启动内核
    func applySubscription(url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            DaemonLogger.shared.log("SUB", "订阅地址为空，清除订阅")
            await clearSubscription()
            return
        }

        DaemonLogger.shared.log("SUB", "保存订阅 → \(trimmed.prefix(40))...")

        // 先关代理
        safelySetProxy(enabled: false)
        DaemonLogger.shared.log("PROXY", "已关闭系统代理")

        do {
            let changed = try await config.downloadIfChanged(url: trimmed)

            guard changed else {
                DaemonLogger.shared.log("SUB", "内容无变化，无需重启内核")
                // 如果内核没在跑还是得拉起来
                if !mihomo.isRunning {
                    try await mihomo.start()
                }
                appState.syncFromServices(mihomo: mihomo, proxy: proxy)
                return
            }

            // 内容有变化 → 停旧内核 → 启新内核
            await stopServices()
            DaemonLogger.shared.log("KERNEL", "正在启动内核...")
            try await mihomo.start()
            DaemonLogger.shared.log("KERNEL", "内核启动成功")

            async let fetchVersion: Void = mihomo.fetchKernelVersion()
            async let refreshProxies: Void = proxy.refreshProxyList()
            _ = await (fetchVersion, refreshProxies)

            appState.syncFromServices(mihomo: mihomo, proxy: proxy)
            DaemonLogger.shared.log("SUB", "订阅更新完成，内核版本: \(mihomo.kernelVersion)")
        } catch {
            logger.error("Failed to apply subscription: \(error.localizedDescription, privacy: .public)")
            DaemonLogger.shared.log("SUB", "❌ 失败: \(error.localizedDescription)")
            appState.resetRuntime()
            appState.lastError = "启动失败: \(error.localizedDescription)"
        }
    }

    private func clearSubscription() async {
        await stopServices()
        appState.resetRuntime()
        settings.subscriptionURL = ""
    }

    private func stopServices() async {
        if mihomo.isRunning {
            DaemonLogger.shared.log("KERNEL", "停止内核")
            mihomo.stop()
        }
        proxy.reset()
    }

    // MARK: - 代理控制

    func toggleProxy() async {
        guard settings.hasSubscriptionURL else {
            appState.lastError = "请先配置订阅地址"
            return
        }
        let action = appState.isProxyEnabled ? "关闭" : "开启"
        DaemonLogger.shared.log("PROXY", "\(action)系统代理")
        if appState.isProxyEnabled {
            safelySetProxy(enabled: false)
        } else {
            // 开启系统代理前确保内核在运行：内核未运行先自动拉起，失败则回滚（不开启代理）
            if !mihomo.isRunning {
                do {
                    DaemonLogger.shared.log("KERNEL", "内核未运行，自动启动中...")
                    try await mihomo.start()
                    async let fetchVersion: Void = mihomo.fetchKernelVersion()
                    async let refreshProxies: Void = proxy.refreshProxyList()
                    _ = await (fetchVersion, refreshProxies)
                    appState.syncFromServices(mihomo: mihomo, proxy: proxy)
                } catch {
                    appState.lastError = "启动代理失败: \(error.localizedDescription)"
                    DaemonLogger.shared.log("PROXY", "❌ 内核启动失败，已取消开启系统代理: \(error.localizedDescription)")
                    return
                }
            }
            safelySetProxy(enabled: true)
        }
        appState.isProxyEnabled = mihomo.isSystemProxyEnabled()
        DaemonLogger.shared.log("PROXY", "当前状态: \(appState.isProxyEnabled ? "已开启" : "已关闭")")
    }

    func selectProxy(name: String, in group: String) async {
        DaemonLogger.shared.log("NODE", "切换节点 [\(group)] → \(name)")
        do {
            try await proxy.selectProxy(name: name, in: group)
            appState.currentSelections = proxy.currentSelections
            DaemonLogger.shared.log("NODE", "切换成功 [\(group)] → \(name)")
        } catch {
            DaemonLogger.shared.log("NODE", "❌ 切换失败 [\(group)]: \(error.localizedDescription)")
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

    // MARK: - 退出

    func prepareForQuit() {
        DaemonLogger.shared.log("APP", "退出应用")
        // 退出前清除本应用开启的系统代理，避免内核停止后系统流量指向死端口导致断网
        if mihomo.isSystemProxyEnabled() {
            safelySetProxy(enabled: false)
            DaemonLogger.shared.log("PROXY", "已关闭系统代理")
        }
        if mihomo.isRunning {
            DaemonLogger.shared.log("KERNEL", "停止内核")
            mihomo.stop()
        }
        proxy.reset()
    }
}

// MARK: - DaemonLogger

/// 守护日志 — 记录关键操作和结果
///
/// 同时输出到：
/// - `~/.config/iclash/daemon.log`（文件日志，便于事后排查，自动滚动）
/// - macOS Unified Logging（通过 `OSLog`），可用 `Console.app` 或 `log show` 查看
@MainActor
struct DaemonLogger {
    static let shared = DaemonLogger()

    /// 单个日志文件最大字节数（1 MB）；超过即触发滚动
    private static let maxFileSize: UInt64 = 1_048_576
    /// 最多保留 1 个历史归档文件（daemon.log.1）
    private static let maxArchivedFiles = 1

    private let logFile: URL
    private let archiveFile: URL
    private let dateFormatter: DateFormatter
    private let osLog: os.Logger
    private let fileHandleQueue = DispatchQueue(label: "com.iclash.daemon-log")
    private let fileManager = FileManager.default

    private init() {
        let home = fileManager.homeDirectoryForCurrentUser
        logFile = home.appendingPathComponent(".config/iclash/daemon.log")
        archiveFile = home.appendingPathComponent(".config/iclash/daemon.log.1")

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "zh_CN")
        dateFormatter = df

        osLog = os.Logger(subsystem: "com.iclash.macos", category: "daemon")
    }

    /// 追加一条日志，自动带时间戳和换行
    func log(_ tag: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(tag) \(message)\n"

        guard let data = line.data(using: .utf8) else { return }

        fileHandleQueue.sync {
            writeToFile(data)
        }

        // 镜像到 Unified Logging（不阻塞 I/O）
        osLog.info("\(line, privacy: .public)")
    }

    /// 读取全部日志（主文件 + 归档文件），通过串行 queue 保护避免读到半截数据
    func readAll() -> String {
        fileHandleQueue.sync {
            let archived = (try? String(contentsOf: archiveFile, encoding: .utf8)) ?? ""
            let current = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
            return archived + current
        }
    }

    /// 清空日志（通过串行 queue 保护）
    func clear() {
        fileHandleQueue.sync {
            try? "".data(using: .utf8)?.write(to: logFile)
            try? fileManager.removeItem(at: archiveFile)
        }
    }

    /// 测试可见：返回日志文件路径
    var logFileURL: URL { logFile }

    // MARK: - 私有

    private func writeToFile(_ data: Data) {
        ensureLogFileExists()

        guard let handle = try? FileHandle(forWritingTo: logFile) else { return }
        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }

        rotateIfNeeded()
    }

    private func ensureLogFileExists() {
        if !fileManager.fileExists(atPath: logFile.path) {
            fileManager.createFile(atPath: logFile.path, contents: nil)
        }
    }

    /// 当日志文件超过 maxFileSize 时归档旧文件，新建空文件
    private func rotateIfNeeded() {
        let size = (try? fileManager.attributesOfItem(atPath: logFile.path)[.size] as? UInt64) ?? 0
        guard size > Self.maxFileSize else { return }

        try? fileManager.removeItem(at: archiveFile)
        try? fileManager.moveItem(at: logFile, to: archiveFile)
        fileManager.createFile(atPath: logFile.path, contents: nil)
    }
}
