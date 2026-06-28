import Foundation
import os.log

/// 系统网络服务代理管理器（基于 `networksetup` 命令行工具）
///
/// 封装对 `/usr/sbin/networksetup` 的调用，负责：
/// - 列举活跃的网络服务（Wi-Fi、Ethernet 等）
/// - 设置/查询 HTTP/HTTPS/SOCKS 系统代理
@MainActor
final class NetworkServiceManager {
    static let shared = NetworkServiceManager()

    private let logger = Logger(subsystem: "com.iclash.macos", category: "NetworkServiceManager")
    private let toolPath = "/usr/sbin/networksetup"

    /// Mihomo mixed-port：HTTP、HTTPS、SOCKS 三类系统代理统一指向的端口
    let proxyHost = "127.0.0.1"
    let proxyPort: UInt16 = 7890

    private init() {}

    // MARK: - 公共 API

    /// 检查系统代理是否处于"由本应用开启"的状态
    ///
    /// 任意一个查询到的网络服务指向 `proxyHost:proxyPort` 即返回 true
    func isSystemProxyEnabled() -> Bool {
        for service in fetchActiveNetworkServices() {
            if isWebProxyEnabled(on: service) {
                return true
            }
        }
        return false
    }

    /// 设置或清除系统代理（HTTP + HTTPS + SOCKS，均指向 proxyHost:proxyPort）
    func setSystemProxy(enabled: Bool) throws {
        for service in fetchActiveNetworkServices() {
            if enabled {
                try run(["-setwebproxy", service, proxyHost, "\(proxyPort)"], swallowMissingService: true)
                try run(["-setwebproxystate", service, "on"], swallowMissingService: true)
                try run(["-setsecurewebproxy", service, proxyHost, "\(proxyPort)"], swallowMissingService: true)
                try run(["-setsecurewebproxystate", service, "on"], swallowMissingService: true)
                try run(["-setsocksfirewallproxy", service, proxyHost, "\(proxyPort)"], swallowMissingService: true)
                try run(["-setsocksfirewallproxystate", service, "on"], swallowMissingService: true)
            } else {
                try run(["-setwebproxystate", service, "off"], swallowMissingService: true)
                try run(["-setsecurewebproxystate", service, "off"], swallowMissingService: true)
                try run(["-setsocksfirewallproxystate", service, "off"], swallowMissingService: true)
            }
        }
    }

    // MARK: - 内部实现

    /// 列举活跃的网络服务名（去重、去注释行）
    func fetchActiveNetworkServices() -> [String] {
        let task = Process()
        let outputPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: toolPath)
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
            return ["Wi-Fi"]
        }
    }

    /// 查询某个网络服务的 HTTP 代理是否启用，且指向本应用期望的主机端口
    private func isWebProxyEnabled(on service: String) -> Bool {
        let task = Process()
        let outputPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: toolPath)
        task.arguments = ["-getwebproxy", service]
        task.standardOutput = outputPipe
        task.standardError = Pipe()
        task.environment = ProcessInfo.processInfo.environment

        do {
            try task.run()
            task.waitUntilExit()

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)

            // 输出格式: "Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n..."
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

            return isEnabled && server == proxyHost && port == "\(proxyPort)"
        } catch {
            return false
        }
    }

    /// 执行 networksetup 子命令
    /// - Parameter swallowMissingService: 当服务不存在（"Unable to find item in network database"）时是否静默忽略
    private func run(_ arguments: [String], swallowMissingService: Bool = false) throws {
        let task = Process()
        let outputPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: toolPath)
        task.arguments = arguments
        task.standardOutput = outputPipe
        task.standardError = outputPipe

        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

            if swallowMissingService,
               output.localizedCaseInsensitiveContains("Unable to find item in network database") {
                logger.error("networksetup could not find service for arguments: \(arguments.joined(separator: " "), privacy: .public)")
                return
            }

            throw MihomoError.proxyConfigurationFailed(details: output.isEmpty ? nil : output)
        }
    }
}