import Foundation
import os.log

/// Mihomo 内核管理服务
@MainActor
final class MihomoService: ObservableObject {
    static let shared = MihomoService()

    @Published private(set) var isRunning = false
    private(set) var process: Process?
    private(set) var configPath: URL?
    private(set) var apiUrl: URL?

    private let configManager = ConfigManager.shared
    private let logger = Logger(subsystem: "com.iclash.macos", category: "MihomoService")
    private let apiPort: UInt16 = 9090
    private let mixedPort: UInt16 = 7890
    private let statusNotification = Notification.Name("MihomoStatusChanged")

    /// 内核版本
    private(set) var kernelVersion: String = "未知"

    /// 更新内核版本（供外部调用）
    func updateKernelVersion(_ version: String) {
        kernelVersion = version
    }

    private var recentOutput = ""

    private init() {}

    /// 启动 Mihomo
    /// - Parameter setProxy: 是否设置系统代理（默认 true）
    func start() async throws {
        guard !isRunning else { return }

        try cleanupStaleProcesses()
        try disableSystemProxyIfNeeded()

        let configUrl = try await configManager.prepareRuntimeConfigFile()
        let mihomoPath = try getMihomoPath()
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
        process.terminationHandler = { [weak self] process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                self?.logger.error("mihomo terminated with status: \(process.terminationStatus)")
                self?.handleProcessTermination()
            }
        }

        do {
            try process.run()
            self.process = process
            self.configPath = configUrl
            self.apiUrl = URL(string: "http://127.0.0.1:\(apiPort)")

            // 等待进程真正启动（最多 3 秒）
            var waitCount = 0
            while !process.isRunning && waitCount < 30 {
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
                waitCount += 1
            }

            guard process.isRunning else {
                self.process = nil
                self.apiUrl = nil
                throw MihomoError.processExitedImmediately(details: recentOutput)
            }

            updateRunningState(true)

        } catch {
            if process.isRunning {
                process.terminate()
            }
            self.process = nil
            self.apiUrl = nil
            updateRunningState(false)
            logger.error("Failed to start mihomo: \(error.localizedDescription, privacy: .public)")
            throw MihomoError.failedToStart(error, details: recentOutput)
        }
    }

    /// 停止 Mihomo 内核（不清除系统代理）
    func stop() {
        logger.info("Stopping mihomo kernel")

        guard let process = process else {
            return
        }
        process.terminate()
        self.process = nil
        self.apiUrl = nil
        updateRunningState(false)
        logger.info("mihomo process terminated")
    }

    /// 获取 Mihomo 可执行文件路径
    private func getMihomoPath() throws -> URL {
        let bundleMihomo = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/mihomo")
        if FileManager.default.fileExists(atPath: bundleMihomo.path) {
            try validateMihomo(at: bundleMihomo)
            return bundleMihomo
        }

        let configMihomo = configManager.configDirectory.appendingPathComponent("mihomo")
        if FileManager.default.fileExists(atPath: configMihomo.path) {
            try validateMihomo(at: configMihomo)
            return configMihomo
        }

        throw MihomoError.mihomoNotFound
    }

    /// 验证 Mihomo 可执行性
    private func validateMihomo(at url: URL) throws {
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

    /// 设置或清除系统代理（使用 SOCKS 代理）
    func setSystemProxy(enabled: Bool) throws {
        let services = fetchActiveNetworkServices()
        for service in services {
            if enabled {
                try runNetworkSetup(arguments: ["-setsocksfirewallproxy", service, "127.0.0.1", "\(mixedPort)"])
                try runNetworkSetup(arguments: ["-setsocksfirewallproxystate", service, "on"])
            } else {
                try runNetworkSetup(arguments: ["-setsocksfirewallproxystate", service, "off"])
            }
        }
    }

    /// 检查系统 SOCKS 代理是否启用（通过 networksetup 查询）
    func isSystemProxyEnabled() -> Bool {
        let services = fetchActiveNetworkServices()
        for service in services {
            let task = Process()
            let outputPipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            task.arguments = ["-getsocksfirewallproxy", service]
            task.standardOutput = outputPipe
            task.standardError = Pipe()
            task.environment = ProcessInfo.processInfo.environment

            do {
                try task.run()
                task.waitUntilExit()

                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)

                // 检查是否指向 127.0.0.1:7890 且处于开启状态
                // networksetup 输出格式: "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n..."
                let lines = output.lowercased().components(separatedBy: .newlines)
                var isEnabled = false
                var server: String?
                var port: String?

                for line in lines {
                    if line.hasPrefix("enabled:") {
                        isEnabled = line.contains("yes")
                    } else if line.hasPrefix("server:") {
                        server = line.replacingOccurrences(of: "server:", with: "").trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("port:") {
                        port = line.replacingOccurrences(of: "port:", with: "").trimmingCharacters(in: .whitespaces)
                    }
                }

                if isEnabled && server == "127.0.0.1" && port == "7890" {
                    return true
                }
            } catch {
                continue
            }
        }
        return false
    }

    /// 获取当前活跃的网络服务列表
    private func fetchActiveNetworkServices() -> [String] {
        let task = Process()
        let outputPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = ["-listallnetworkservices"]
        task.standardOutput = outputPipe
        task.standardError = outputPipe
        task.environment = ProcessInfo.processInfo.environment

        do {
            try task.run()
            task.waitUntilExit()

            guard task.terminationStatus == 0 else {
                logger.error("networksetup -listallnetworkservices failed with status \(task.terminationStatus)")
                return ["Wi-Fi"] // 回退默认值
            }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)

            return output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { line in
                    guard !line.isEmpty else { return false }
                    if line.hasPrefix("An asterisk") || line.hasPrefix("networksetup") {
                        return false
                    }
                    return !line.hasPrefix("*")
                }
        } catch {
            logger.error("Failed to enumerate network services: \(error.localizedDescription, privacy: .public)")
            return ["Wi-Fi"] // 出错时回退默认值
        }
    }

    private func appendRecentOutput(_ output: String) {
        let combined = recentOutput.isEmpty ? output : recentOutput + "\n" + output
        recentOutput = String(combined.suffix(2_000))
    }

    private func disableSystemProxyIfNeeded() throws {
        do {
            try setSystemProxy(enabled: false)
        } catch {
            logger.error("Failed to clear stale system proxy before startup: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

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

            guard task.terminationStatus == 0 else {
                continue
            }

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

    private func runNetworkSetup(arguments: [String]) throws {
        let task = Process()
        let outputPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = arguments
        task.standardOutput = outputPipe
        task.standardError = outputPipe

        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

            if output.localizedCaseInsensitiveContains("Unable to find item in network database") {
                logger.error("networksetup could not find service for arguments: \(arguments.joined(separator: " "), privacy: .public)")
                return
            }

            throw MihomoError.proxyConfigurationFailed(details: output.isEmpty ? nil : output)
        }
    }

    private func handleProcessTermination() {
        let wasRunning = isRunning
        process = nil
        apiUrl = nil

        if wasRunning {
            try? setSystemProxy(enabled: false)
        }
        updateRunningState(false)
    }

    private func updateRunningState(_ isRunning: Bool) {
        self.isRunning = isRunning
        NotificationCenter.default.post(name: statusNotification, object: nil)
    }
}

/// 代理配置
struct ProxyInfo: Codable {
    let name: String
    let type: String
    let all: [String]?
    let now: String?
}

struct ProxiesResponse: Codable {
    let proxies: [String: ProxyInfo]
}

// MARK: - API

extension MihomoService {
    /// 获取所有代理
    func fetchProxies() async throws -> [String: ProxyInfo] {
        guard let apiUrl = apiUrl else {
            throw MihomoError.apiNotAvailable
        }

        let url = apiUrl.appendingPathComponent("proxies")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        // 重试机制
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let response = try JSONDecoder().decode(ProxiesResponse.self, from: data)
                return response.proxies
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 重试前等待 0.5 秒
                }
            }
        }
        throw lastError ?? MihomoError.apiNotAvailable
    }

    /// 选择代理
    func selectProxy(name: String, in group: String) async throws {
        guard let apiUrl = apiUrl else {
            throw MihomoError.apiNotAvailable
        }

        // URL 编码 group name
        let encodedGroup = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        let url = apiUrl.appendingPathComponent("proxies/\(encodedGroup)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": name])
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 204 else {
            throw MihomoError.apiSelectFailed
        }
    }

    /// 获取内核版本（带重试）
    func fetchKernelVersion() async {
        guard let apiUrl = apiUrl else { return }

        let url = apiUrl.appendingPathComponent("version")

        for attempt in 0..<2 {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let version = json["version"] as? String {
                    self.kernelVersion = version
                    return
                }
            } catch {
                // 只在最后一次失败时记录错误
                if attempt == 1 {
                    logger.error("Failed to fetch kernel version: \(error.localizedDescription, privacy: .public)")
                }
            }

            if attempt < 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}

/// 错误类型
enum MihomoError: LocalizedError {
    case mihomoNotFound
    case mihomoNotExecutable
    case networkServiceNotFound
    case processExitedImmediately(details: String? = nil)
    case proxyConfigurationFailed(details: String? = nil)
    case failedToStart(Error, details: String? = nil)
    case apiNotAvailable
    case apiSelectFailed

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
        }
    }
}
