import Foundation

/// Mihomo 内核管理服务
final class MihomoService: ObservableObject {
    static let shared = MihomoService()

    @Published private(set) var isRunning = false
    private(set) var process: Process?
    private(set) var configPath: URL?
    private(set) var apiUrl: URL?

    private let configManager = ConfigManager.shared
    private let apiPort: UInt16 = 9090
    private let httpPort: UInt16 = 7892
    private let socksPort: UInt16 = 7891
    private let statusNotification = Notification.Name("MihomoStatusChanged")

    /// 内核版本
    private(set) var kernelVersion: String = "未知"

    /// 更新内核版本（供外部调用）
    func updateKernelVersion(_ version: String) {
        kernelVersion = version
    }

    private let queue = DispatchQueue(label: "com.iclash.mihomo-service", attributes: .concurrent)

    private init() {}

    /// 启动 Mihomo
    func start() async throws {
        guard !isRunning else { return }

        let configUrl = try await configManager.prepareRuntimeConfigFile()
        let mihomoPath = try getMihomoPath()
        print("[MihomoService] starting mihomo: \(mihomoPath.path)")
        print("[MihomoService] using config: \(configUrl.path)")

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
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { return }

            print("[mihomo] \(output)")
        }
        process.terminationHandler = { [weak self] process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            print("[MihomoService] process terminated with status: \(process.terminationStatus)")
            self?.handleProcessTermination()
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
                throw MihomoError.processExitedImmediately
            }

            updateRunningState(true)
            try setSystemProxy(enabled: true)
            await fetchKernelVersion()

        } catch {
            if process.isRunning {
                process.terminate()
            }
            self.process = nil
            self.apiUrl = nil
            updateRunningState(false)
            throw MihomoError.failedToStart(error)
        }
    }

    /// 停止 Mihomo
    func stop() {
        print("[MihomoService] stop() called, isRunning: \(isRunning), process: \(process != nil)")

        // 清除系统代理（无论 process 是否存在）
        do {
            try setSystemProxy(enabled: false)
            print("[MihomoService] setSystemProxy(enabled: false) success")
        } catch {
            print("[MihomoService] setSystemProxy failed: \(error)")
        }

        guard let process = process else {
            print("[MihomoService] process is nil, returning")
            return
        }
        process.terminate()
        self.process = nil
        self.apiUrl = nil
        updateRunningState(false)
        print("[MihomoService] process terminated")
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
    private func setSystemProxy(enabled: Bool) throws {
        let services = fetchActiveNetworkServices()
        for service in services {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")

            if enabled {
                task.arguments = ["-setsocksfirewallproxy", service, "127.0.0.1", "\(socksPort)"]
            } else {
                task.arguments = ["-setsocksfirewallproxystate", service, "off"]
            }

            try task.run()
            task.waitUntilExit()
        }
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
                return ["Wi-Fi"] // 回退默认值
            }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)

            let knownKeywords = ["Wi-Fi", "Ethernet", "Thunderbolt Bridge", "USB 10/100/1000", "WAN", "LAN"]

            return output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { line in
                    guard !line.isEmpty else { return false }
                    if line.hasPrefix("An asterisk") || line.hasPrefix("networksetup") {
                        return false
                    }
                    return knownKeywords.contains { line.contains($0) }
                }
        } catch {
            return ["Wi-Fi"] // 出错时回退默认值
        }
    }

    private func handleProcessTermination() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            let wasRunning = self.isRunning
            self.process = nil
            self.apiUrl = nil

            if wasRunning {
                try? self.setSystemProxy(enabled: false)
            }
            self.updateRunningState(false)
        }
    }

    private func updateRunningState(_ isRunning: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRunning = isRunning
            NotificationCenter.default.post(name: self.statusNotification, object: nil)
        }
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

    /// 获取内核版本
    func fetchKernelVersion() async {
        guard let apiUrl = apiUrl else { return }

        let url = apiUrl.appendingPathComponent("version")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = json["version"] as? String {
                self.kernelVersion = version
            }
        } catch {
            print("[MihomoService] 获取内核版本失败: \(error)")
        }
    }
}

/// 错误类型
enum MihomoError: LocalizedError {
    case mihomoNotFound
    case mihomoNotExecutable
    case networkServiceNotFound
    case processExitedImmediately
    case proxyConfigurationFailed
    case failedToStart(Error)
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
        case .processExitedImmediately:
            return "Mihomo 启动后立即退出"
        case .proxyConfigurationFailed:
            return "系统代理配置失败"
        case .failedToStart(let error):
            return "Mihomo 启动失败: \(error.localizedDescription)"
        case .apiNotAvailable:
            return "API 不可用"
        case .apiSelectFailed:
            return "切换代理失败"
        }
    }
}
