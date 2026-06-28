import Foundation
import os.log

/// 配置文件管理器
@MainActor
final class ConfigManager {
    static let shared = ConfigManager()

    private let logger = Logger(subsystem: "com.iclash.macos", category: "ConfigManager")
    private let directSession: URLSession
    private let settings = AppSettings.shared

    /// Mihomo 原生支持的代理 URI 协议
    private static let supportedSchemes: Set<String> = [
        "anytls", "ss", "shadowsocks", "vmess", "vless", "trojan",
        "hysteria", "hysteria2", "hy2", "tuic", "socks5", "http"
    ]

    /// proxy-provider 文件名（相对 configDirectory）
    private static let providerFileName = "providers.txt"

    let configDirectory: URL
    let runtimeConfigFile: URL

    /// 订阅地址（从设置中获取）
    var subscriptionURL: String {
        settings.subscriptionURL
    }

    /// 运行时配置文件是否存在
    var runtimeConfigFileExists: Bool {
        FileManager.default.fileExists(atPath: runtimeConfigFile.path)
    }

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0,
            kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0
        ]
        directSession = URLSession(configuration: configuration)

        let home = FileManager.default.homeDirectoryForCurrentUser
        configDirectory = home.appendingPathComponent(".config/iclash", isDirectory: true)
        runtimeConfigFile = configDirectory.appendingPathComponent("config.yaml")
        try? createDirectoryIfNeeded()
        try? ensureGeoIPExists()
    }

    /// 确保 GeoIP 数据库存在（从 Bundle 创建符号链接，不占用额外空间）
    private func ensureGeoIPExists() throws {
        let geoipPath = configDirectory.appendingPathComponent("Country.mmdb")
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: geoipPath.path) {
            let resourceValues = try? geoipPath.resourceValues(forKeys: [.isSymbolicLinkKey])
            if resourceValues?.isSymbolicLink == true {
                let realPath = try fileManager.destinationOfSymbolicLink(atPath: geoipPath.path)
                if !fileManager.fileExists(atPath: realPath) {
                    try fileManager.removeItem(at: geoipPath)
                }
            }
        }

        guard !fileManager.fileExists(atPath: geoipPath.path) else { return }

        guard let resourcePath = Bundle.main.resourceURL else { return }
        let bundleGeoIP = resourcePath.appendingPathComponent("Country.mmdb")
        guard fileManager.fileExists(atPath: bundleGeoIP.path) else { return }

        try fileManager.createSymbolicLink(at: geoipPath, withDestinationURL: bundleGeoIP)
    }

    /// 获取运行时配置文件路径（文件已存在时跳过下载）
    func prepareRuntimeConfigFile() async throws -> URL {
        if FileManager.default.fileExists(atPath: runtimeConfigFile.path) {
            return runtimeConfigFile
        }
        do {
            try await refreshRuntimeConfig()
        } catch {
            if FileManager.default.fileExists(atPath: runtimeConfigFile.path) {
                return runtimeConfigFile
            }
            throw error
        }

        return runtimeConfigFile
    }

    /// 下载订阅并保存到 config.yaml（带重试）
    func downloadAndValidateConfig(url: String, retryCount: Int = 3) async throws -> URL {
        guard URL(string: url) != nil else {
            throw ConfigError.invalidSubscriptionURL
        }

        logger.info("Downloading subscription from \(url, privacy: .private(mask: .hash))")

        var lastError: Error?

        for attempt in 0..<retryCount {
            do {
                let content = try await downloadSubscriptionContent(from: url)
                try Data(content.utf8).write(to: runtimeConfigFile, options: .atomic)
                logger.info("Wrote runtime config to \(self.runtimeConfigFile.path, privacy: .public), size: \(content.count)")
                return runtimeConfigFile
            } catch {
                lastError = error
                logger.warning("Download attempt \(attempt + 1) failed: \(error.localizedDescription, privacy: .public)")
                if attempt < retryCount - 1 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        throw lastError ?? ConfigError.networkError(NSError(domain: "ConfigManager", code: -1))
    }

    /// 从订阅地址生成运行配置
    func refreshRuntimeConfig() async throws {
        logger.info("Refreshing runtime config from subscription")
        let content = try await downloadSubscriptionContent(from: subscriptionURL)
        try Data(content.utf8).write(to: runtimeConfigFile, options: .atomic)
        logger.info("Updated runtime config at \(self.runtimeConfigFile.path, privacy: .public), size: \(content.count)")
    }

    /// 下载订阅内容并验证
    private func downloadSubscriptionContent(from urlString: String) async throws -> String {
        guard let subscriptionURL = URL(string: urlString) else {
            throw ConfigError.invalidSubscriptionURL
        }

        var request = URLRequest(
            url: subscriptionURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.setValue("Mihomo/1.18.1", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await directSession.data(for: request)
        } catch {
            logger.error("Subscription request failed: \(error.localizedDescription, privacy: .public)")
            throw ConfigError.networkError(error)
        }

        if let httpResponse = response as? HTTPURLResponse {
            logger.info("Subscription response status: \(httpResponse.statusCode), bytes: \(data.count)")
            guard (200...299).contains(httpResponse.statusCode) else {
                throw ConfigError.invalidResponse(statusCode: httpResponse.statusCode)
            }
        }

        guard !data.isEmpty else {
            throw ConfigError.emptySubscription
        }

        var content = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !content.isEmpty else {
            throw ConfigError.emptySubscription
        }

        logger.debug("Downloaded subscription text length: \(content.count), raw bytes: \(data.count)")

        if content.contains("\"error\"") && content.localizedCaseInsensitiveContains("access denied") {
            throw ConfigError.subscriptionBlocked
        }

        // 尝试 Base64 解码
        if let decodedContent = try? base64Decode(content) {
            logger.info("Subscription content was base64 encoded, decoded length: \(decodedContent.count)")
            content = decodedContent
        }

        content = try normalizeSubscriptionContent(content)

        return content
    }

    // MARK: - 订阅内容处理

    /// 归一化订阅内容：URI 列表 → proxy-provider + config.yaml；完整 YAML → 直通
    func normalizeSubscriptionContent(_ content: String) throws -> String {
        if isURIList(content) {
            logger.info("Detected proxy URI list, generating config with proxy-providers")
            try saveProviderFile(content)
            return generateConfigWithProviders()
        }
        logger.info("Subscription content is already a config file")
        return content
    }

    /// 检查内容是否为纯 URI 列表（每行都是支持的 URI 格式）
    private func isURIList(_ content: String) -> Bool {
        let lines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard !lines.isEmpty else { return false }

        return lines.allSatisfy { line in
            Self.supportedSchemes.contains { scheme in
                line.hasPrefix("\(scheme)://")
            }
        }
    }

    /// 将 URI 列表保存为 Mihomo proxy-provider 文件
    private func saveProviderFile(_ content: String) throws {
        let providerPath = configDirectory.appendingPathComponent(Self.providerFileName)
        try Data(content.utf8).write(to: providerPath, options: .atomic)
        logger.info("Saved provider file to \(providerPath.path, privacy: .public)")
    }

    /// 生成使用 proxy-providers 的完整配置
    private func generateConfigWithProviders() -> String {
        """
        \(DefaultRules.baseConfig)
        proxy-providers:
          mysub:
            type: file
            path: \(Self.providerFileName)
            health-check:
              enable: true
              url: http://www.gstatic.com/generate_204
              interval: 300

        proxy-groups:
          - { name: BoostNet, type: select, proxies: [自动选择, 故障转移, DIRECT], use: [mysub] }
          - { name: 自动选择, type: url-test, use: [mysub], url: 'http://www.gstatic.com/generate_204', interval: 300, tolerance: 50 }
          - { name: 故障转移, type: fallback, use: [mysub], url: 'http://www.gstatic.com/generate_204', interval: 300 }
        \(DefaultRules.rulesSection)
        """
    }

    // MARK: - Base64 解码

    /// Base64 解码
    private func base64Decode(_ string: String) throws -> String {
        var base64String = string
        if let range = string.range(of: "base64,") {
            base64String = String(string[range.upperBound...])
        }

        guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else {
            throw ConfigError.invalidSubscriptionURL
        }

        guard let decodedString = String(data: data, encoding: .utf8) else {
            throw ConfigError.invalidSubscriptionURL
        }

        return decodedString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 文件操作

    private func createDirectoryIfNeeded() throws {
        if !FileManager.default.fileExists(atPath: configDirectory.path) {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - 配置解析

    /// 解析 config.yaml 中 proxy-groups 的顺序
    func parseProxyGroupsOrder() -> [String] {
        guard let content = try? String(contentsOf: runtimeConfigFile, encoding: .utf8) else {
            return []
        }

        var groups: [String] = []
        var inProxyGroups = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "proxy-groups:" {
                inProxyGroups = true
                continue
            }

            guard inProxyGroups else { continue }

            // 遇到下一个顶级 key 则结束
            if !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix(" ") && !trimmed.hasPrefix("\t") {
                break
            }

            // 提取 inline 格式: - { name: xxx, ... }
            if trimmed.hasPrefix("- {") {
                if let nameRange = trimmed.range(of: "name:"),
                   let commaOrEnd = trimmed[nameRange.upperBound...].firstIndex(of: ",") {
                    let name = String(trimmed[nameRange.upperBound..<commaOrEnd])
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    if !name.isEmpty { groups.append(name) }
                }
            }
        }

        return groups
    }
}

// MARK: - 错误类型

enum ConfigError: LocalizedError {
    case invalidSubscriptionURL
    case invalidResponse(statusCode: Int? = nil)
    case emptySubscription
    case subscriptionBlocked
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidSubscriptionURL:
            return "订阅地址无效"
        case .invalidResponse(let statusCode):
            if let statusCode {
                return "订阅地址返回了无效响应，HTTP \(statusCode)"
            }
            return "订阅地址返回了无效响应"
        case .emptySubscription:
            return "订阅内容为空"
        case .subscriptionBlocked:
            return "订阅请求被服务端拦截"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        }
    }
}
