import Foundation
import os.log

/// Mihomo 内核管理服务
///
/// 职责范围（已拆分后）：
/// - 内核进程生命周期（启动/停止/崩溃循环检测/僵尸进程清理）
/// - 内核版本探测（通过 MihomoAPIClient）
/// - 系统代理开关（通过 NetworkServiceManager）
@MainActor
final class MihomoService: ObservableObject {
    static let shared = MihomoService()

    @Published private(set) var isRunning = false
    private(set) var process: Process?
    private(set) var configPath: URL?
    private(set) var apiUrl: URL?

    private let configManager: any ConfigManagerProtocol
    private let networkService: NetworkServiceManager
    private let logger = Logger(subsystem: "com.iclash.macos", category: "MihomoService")
    private let apiPort: UInt16 = 9090
    private let mixedPort: UInt16 = 7890

    /// 内核版本
    private(set) var kernelVersion: String = "未知"

    /// 崩溃时间戳（用于崩溃循环检测）
    private var crashTimestamps: [Date] = []
    private let crashThreshold = 3
    private let crashWindow: TimeInterval = 30

    /// 内核最近输出（用于启动失败时回显给用户）
    private var recentOutput = ""

    /// 通过构造器注入依赖（便于测试替换）
    init(configManager: any ConfigManagerProtocol = ConfigManager.shared,
         networkService: NetworkServiceManager = .shared) {
        self.configManager = configManager
        self.networkService = networkService
    }

    // MARK: - 崩溃循环检测

    func recordCrash() {
        crashTimestamps.append(Date())
    }

    func resetCrashCounters() {
        crashTimestamps.removeAll()
    }

    func isInCrashLoop() -> Bool {
        let now = Date()
        crashTimestamps = crashTimestamps.filter { now.timeIntervalSince($0) < crashWindow }
        return crashTimestamps.count >= crashThreshold
    }

    // MARK: - 生命周期

    /// 启动 Mihomo
    func start() async throws {
        guard !isRunning else { return }

        if isInCrashLoop() {
            throw MihomoError.crashLoopDetected
        }

        try cleanupStaleProcesses()

        let configUrl = try await configManager.prepareRuntimeConfigFile()
        let mihomoPath = try resolveMihomoPath()
        logger.info("Starting mihomo at \(mihomoPath.path, privacy: .public)")
        logger.info("Using runtime config at \(configUrl.path, privacy: .public)")
        recentOutput = ""

        let process = Process()
        process.executableURL = mihomoPath
        process.arguments = [
            "-d", configManager.configDirectory.path,
            "-f", configUrl.path
        ]
        process.environment = ProcessInfo.processInfo.environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { return }

            Task { @MainActor [weak self] in
                self?.appendRecentOutput(output)
                self?.logger.debug("[mihomo] \(output, privacy: .public)")
            }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                guard let self, self.process === terminatedProcess else { return }
                self.handleProcessTermination(
                    reason: terminatedProcess.terminationReason,
                    status: terminatedProcess.terminationStatus
                )
            }
        }

        do {
            try process.run()
            self.process = process
            self.configPath = configUrl
            self.apiUrl = URL(string: "http://127.0.0.1:\(apiPort)")

            // 通过 API 探测确认内核真正就绪（最多 3 秒），比单纯检查进程更可靠
            let client = MihomoAPIClient(apiBaseURL: self.apiUrl!)
            var probed = false
            for _ in 0..<10 {
                try await Task.sleep(nanoseconds: 300_000_000) // 0.3 秒
                if let version = await client.fetchKernelVersion(retryCount: 1), !version.isEmpty {
                    self.kernelVersion = version
                    probed = true
                    break
                }
            }

            guard process.isRunning else {
                self.process = nil
                self.apiUrl = nil
                DaemonLogger.shared.log("KERNEL", "❌ 启动后立即退出: \(recentOutput.prefix(200))")
                throw MihomoError.processExitedImmediately(details: recentOutput)
            }

            isRunning = true
            resetCrashCounters()
            DaemonLogger.shared.log("KERNEL", "启动成功，PID: \(process.processIdentifier)")

        } catch let error as MihomoError {
            if process.isRunning { process.terminate() }
            self.process = nil
            self.apiUrl = nil
            isRunning = false
            DaemonLogger.shared.log("KERNEL", "❌ 启动失败: \(error.localizedDescription)")
            throw error
        } catch {
            if process.isRunning { process.terminate() }
            self.process = nil
            self.apiUrl = nil
            isRunning = false
            logger.error("Failed to start mihomo: \(error.localizedDescription, privacy: .public)")
            DaemonLogger.shared.log("KERNEL", "❌ 启动异常: \(error.localizedDescription)")
            throw MihomoError.failedToStart(error, details: recentOutput)
        }
    }

    /// 停止 Mihomo 内核（不清除系统代理）
    func stop() {
        logger.info("Stopping mihomo kernel")

        guard let process = process else {
            isRunning = false
            return
        }
        let pid = process.processIdentifier
        process.terminate()
        self.process = nil
        self.apiUrl = nil
        isRunning = false
        DaemonLogger.shared.log("KERNEL", "已停止 (PID: \(pid))")
    }

    // MARK: - 系统代理

    func setSystemProxy(enabled: Bool) throws {
        try networkService.setSystemProxy(enabled: enabled)
    }

    func isSystemProxyEnabled() -> Bool {
        networkService.isSystemProxyEnabled()
    }

    // MARK: - 内核版本

    /// 获取内核版本（带重试）；成功时更新 `kernelVersion` 属性
    func fetchKernelVersion() async {
        guard let apiUrl = apiUrl else { return }
        let client = MihomoAPIClient(apiBaseURL: apiUrl)
        if let version = await client.fetchKernelVersion() {
            self.kernelVersion = version
        }
    }

    // MARK: - 代理 API（透传到 MihomoAPIClient）

    func fetchProxies() async throws -> [String: ProxyInfo] {
        guard let apiUrl = apiUrl else {
            throw MihomoError.apiNotAvailable
        }
        return try await MihomoAPIClient(apiBaseURL: apiUrl).fetchProxies()
    }

    func selectProxy(name: String, in group: String) async throws {
        guard let apiUrl = apiUrl else {
            throw MihomoError.apiNotAvailable
        }
        try await MihomoAPIClient(apiBaseURL: apiUrl).selectProxy(name: name, in: group)
    }

    // MARK: - 内核路径解析

    private func resolveMihomoPath() throws -> URL {
        let bundleMihomo = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/mihomo")
        let configMihomo = configManager.configDirectory.appendingPathComponent("mihomo")
        return try Self.resolveMihomoPath(bundleMihomo: bundleMihomo, configMihomo: configMihomo)
    }

    /// 优先使用用户配置目录中的 Mihomo 二进制；若不存在或不合法，则从 Bundle 引导/修复
    ///
    /// 决策流程：
    /// 1. config 目录下的 mihomo 存在且合法 → 使用 config 版本（用户安装的优先）
    /// 2. config 目录下的 mihomo 缺失 → 从 Bundle 复制（引导）
    /// 3. config 目录下的 mihomo 存在但非法（如目录、无可执行权限）→ 从 Bundle 复制（修复）
    /// 4. Bundle 中的 mihomo 也不存在或不可执行 → 抛错
    static func resolveMihomoPath(bundleMihomo: URL, configMihomo: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: bundleMihomo.path) else {
            throw MihomoError.mihomoNotFound
        }
        try validateMihomo(at: bundleMihomo)

        // 尝试使用 config 目录的版本
        if FileManager.default.fileExists(atPath: configMihomo.path) {
            do {
                try validateMihomo(at: configMihomo)
                return configMihomo
            } catch {
                // config 版本非法 → 修复
                try bootstrapMihomo(from: bundleMihomo, to: configMihomo)
                return configMihomo
            }
        }

        // config 版本缺失 → 引导
        try bootstrapMihomo(from: bundleMihomo, to: configMihomo)
        return configMihomo
    }

    /// 从 Bundle 复制 mihomo 到 config 目录（目标已存在时覆盖）
    private static func bootstrapMihomo(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    private static func validateMihomo(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            throw MihomoError.mihomoNotFound
        }
        if isDirectory.boolValue {
            throw MihomoError.mihomoNotFound
        }
        if !FileManager.default.isExecutableFile(atPath: url.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        if !FileManager.default.isExecutableFile(atPath: url.path) {
            throw MihomoError.mihomoNotExecutable
        }
    }

    // MARK: - 内部

    /// 追加内核输出（保留最近 2000 字符用于错误回显）
    private func appendRecentOutput(_ output: String) {
        let combined = recentOutput.isEmpty ? output : recentOutput + "\n" + output
        recentOutput = String(combined.suffix(2_000))
    }

    /// 清理占用 mixedPort/apiPort 的残留 mihomo 进程
    private func cleanupStaleProcesses() throws {
        for port in [apiPort, mixedPort] {
            let task = Process()
            let outputPipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
            task.standardOutput = outputPipe
            task.standardError = Pipe()

            try task.run()
            task.waitUntilExit()

            guard task.terminationStatus == 0 else { continue }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
            let entries = output.split(separator: "\n")

            var pid: Int32?
            var command: String?

            for entry in entries {
                guard let prefix = entry.first else { continue }
                let value = String(entry.dropFirst())
                switch prefix {
                case "p":
                    pid = Int32(value)
                case "c":
                    command = value
                default:
                    break
                }

                if let pid, let command, command.localizedCaseInsensitiveContains("mihomo") {
                    logger.info("Terminating stale mihomo process \(pid) on port \(port)")
                    kill(pid, SIGTERM)
                    _ = waitpid(pid, nil, 0)
                    break
                }
            }
        }
    }

    /// 处理进程终止事件：通过 `terminationReason` 区分主动停止和崩溃
    /// - `.exit`: 正常退出（用户调用 stop()）
    /// - `.uncaughtSignal`: 异常退出（崩溃）
    private func handleProcessTermination(reason: Process.TerminationReason, status: Int32) {
        let wasRunning = isRunning
        process = nil
        apiUrl = nil
        isRunning = false

        guard wasRunning else { return }

        switch reason {
        case .exit:
            // 主动 stop() → 静默
            logger.info("mihomo exited normally with status \(status)")
        case .uncaughtSignal:
            logger.error("mihomo crashed with signal (status \(status))")
            DaemonLogger.shared.log("KERNEL", "❌ 意外崩溃，将自动重启")
            NotificationCenter.default.post(name: .mihomoCrashed, object: nil)
        @unknown default:
            logger.error("mihomo terminated with unknown reason, status \(status)")
            DaemonLogger.shared.log("KERNEL", "❌ 异常退出，将自动重启")
            NotificationCenter.default.post(name: .mihomoCrashed, object: nil)
        }
    }
}

// MARK: - 错误类型

enum MihomoError: LocalizedError {
    case mihomoNotFound
    case mihomoNotExecutable
    case networkServiceNotFound
    case processExitedImmediately(details: String? = nil)
    case proxyConfigurationFailed(details: String? = nil)
    case failedToStart(Error, details: String? = nil)
    case apiNotAvailable
    case apiSelectFailed
    case crashLoopDetected

    var errorDescription: String? {
        switch self {
        case .mihomoNotFound:
            return "Mihomo 内核文件未找到"
        case .mihomoNotExecutable:
            return "Mihomo 内核文件不可执行"
        case .networkServiceNotFound:
            return "未找到可用的网络服务"
        case .processExitedImmediately(let details):
            if let details, !details.isEmpty {
                return "Mihomo 启动后立即退出\n\(details)"
            }
            return "Mihomo 启动后立即退出"
        case .proxyConfigurationFailed(let details):
            if let details, !details.isEmpty {
                return "系统代理配置失败\n\(details)"
            }
            return "系统代理配置失败"
        case .failedToStart(let error, let details):
            if let details, !details.isEmpty {
                return "Mihomo 启动失败: \(error.localizedDescription)\n\(details)"
            }
            return "Mihomo 启动失败: \(error.localizedDescription)"
        case .apiNotAvailable:
            return "API 不可用"
        case .apiSelectFailed:
            return "切换代理失败"
        case .crashLoopDetected:
            return "Mihomo 内核反复崩溃，已停止自动重启"
        }
    }
}