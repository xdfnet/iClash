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

    /// 订阅内容最大字节数（5 MB）— 超过此大小视为异常，避免恶意订阅 OOM
    static let maxSubscriptionBytes = 5 * 1_024 * 1_024

    /// 校验订阅内容是否在允许大小内；越界时抛出 `ConfigError.subscriptionTooLarge`
    static func validateSubscriptionSize(bytes: Int) throws {
        guard bytes <= maxSubscriptionBytes else {
            throw ConfigError.subscriptionTooLarge(declaredBytes: bytes)
        }
    }

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
        try? ensureKernelExists()
    }

    /// 确保 mihomo 内核存在于配置目录（从 Bundle 复制，损坏或 Bundle 更新时覆盖）
    ///
    /// 决策优先级：
    /// 1. config 目录缺失/不可执行 → 复制（引导/修复）
    /// 2. Bundle 文件修改时间比 config 版本新 → 覆盖（App 更新后自动同步新版内核）
    /// 3. 以上均不满足 → 跳过
    private func ensureKernelExists() throws {
        let fm = FileManager.default
        let kernelPath = configDirectory.appendingPathComponent("mihomo")
        let bundleKernel = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/mihomo")

        guard fm.fileExists(atPath: bundleKernel.path) else { return }

        let needsCopy: Bool
        if fm.fileExists(atPath: kernelPath.path) {
            if !fm.isExecutableFile(atPath: kernelPath.path) {
                needsCopy = true
                try? fm.removeItem(at: kernelPath)
            } else if isBundleResourceNewer(bundleKernel, configCopy: kernelPath) {
                needsCopy = true
                try? fm.removeItem(at: kernelPath)
            } else {
                needsCopy = false
            }
        } else {
            needsCopy = true
        }

        if needsCopy {
            try? fm.copyItem(at: bundleKernel, to: kernelPath)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kernelPath.path)
        }
    }

    /// 确保 GeoIP 数据库存在于配置目录（从 Bundle 复制，损坏或 Bundle 更新时覆盖）
    ///
    /// 行为：
    /// - 配置目录中无 Country.mmdb → 从 Bundle 复制
    /// - 配置目录中已有但文件大小异常（< 1MB）→ 重新复制（修复损坏）
    /// - Bundle 文件修改时间比 config 版本新 → 覆盖（App 更新后自动同步新版 mmdb）
    /// - Bundle 中无 Country.mmdb → 跳过（降级，不影响主流程）
    private func ensureGeoIPExists() throws {
        let geoipPath = configDirectory.appendingPathComponent("Country.mmdb")
        let fileManager = FileManager.default

        guard let resourcePath = Bundle.main.resourceURL else { return }
        let bundleGeoIP = resourcePath.appendingPathComponent("Country.mmdb")
        guard fileManager.fileExists(atPath: bundleGeoIP.path) else { return }

        let needsCopy: Bool
        if fileManager.fileExists(atPath: geoipPath.path) {
            let attrs = try? fileManager.attributesOfItem(atPath: geoipPath.path)
            let size = attrs?[.size] as? UInt64 ?? 0
            if size < 1_048_576 {
                needsCopy = true
                try? fileManager.removeItem(at: geoipPath)
            } else if isBundleResourceNewer(bundleGeoIP, configCopy: geoipPath) {
                needsCopy = true
                try? fileManager.removeItem(at: geoipPath)
            } else {
                needsCopy = false
            }
        } else {
            needsCopy = true
        }

        if needsCopy {
            try fileManager.copyItem(at: bundleGeoIP, to: geoipPath)
        }
    }

    /// 判断 Bundle 中的资源文件是否比 config 目录中的副本更新
    /// - Returns: true 当 Bundle 文件的修改时间 > config 副本的修改时间
    private func isBundleResourceNewer(_ bundleFile: URL, configCopy: URL) -> Bool {
        let fm = FileManager.default
        guard let bundleDate = try? fm.attributesOfItem(atPath: bundleFile.path)[.modificationDate] as? Date,
              let configDate = try? fm.attributesOfItem(atPath: configCopy.path)[.modificationDate] as? Date else {
            return false
        }
        return bundleDate > configDate
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

    /// 下载订阅、检测类型，仅内容变化时写入磁盘
    /// - Returns: true=内容已更新并写入磁盘；false=内容无变化，跳过
    func downloadIfChanged(url: String, retryCount: Int = 3) async throws -> Bool {
        guard URL(string: url) != nil else {
            throw ConfigError.invalidSubscriptionURL
        }

        logger.info("Downloading subscription from \(url, privacy: .private(mask: .hash))")

        var lastError: Error?

        for attempt in 0..<retryCount {
            do {
                let rawContent = try await downloadSubscriptionContent(from: url)
                guard !rawContent.isEmpty else { throw ConfigError.emptySubscription }

                let configContent = generateConfigContent(from: rawContent)

                if !isContentChanged(rawContent) {
                    DaemonLogger.shared.log("SUB", "内容无变化，跳过")
                    return false
                }

                try saveContent(rawContent, configContent: configContent)
                DaemonLogger.shared.log("SUB", "内容已更新，写入磁盘")
                return true
            } catch {
                lastError = error
                let errMsg = error.localizedDescription
                logger.warning("Download attempt \(attempt + 1) failed: \(errMsg, privacy: .public)")
                DaemonLogger.shared.log("SUB", "⚠️ 下载失败 (第\(attempt + 1)次): \(errMsg)")
                if attempt < retryCount - 1 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        throw lastError ?? ConfigError.networkError(NSError(domain: "ConfigManager", code: -1))
    }

    /// 从订阅地址生成运行配置（仅首次启动无 config.yaml 时调用）
    func refreshRuntimeConfig() async throws {
        logger.info("Refreshing runtime config from subscription")
        let rawContent = try await downloadSubscriptionContent(from: subscriptionURL)
        let configContent = generateConfigContent(from: rawContent)
        try saveContent(rawContent, configContent: configContent)
        logger.info("Updated runtime config at \(self.runtimeConfigFile.path, privacy: .public)")
    }

    /// 下载订阅内容并验证
    ///
    /// 大小保护：
    /// - 若响应头声明 `Content-Length` 超过上限，直接拒绝（避免下载大文件被 OOM）
    /// - 通过 URLSessionConfiguration 的 `httpMaximumConnectionsPerHost`/timeout 间接保护
    private func downloadSubscriptionContent(from urlString: String) async throws -> String {
        guard let subscriptionURL = URL(string: urlString) else {
            throw ConfigError.invalidSubscriptionURL
        }

        var request = URLRequest(
            url: subscriptionURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.setValue("Mihomo/1.19.27", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await directSession.data(for: request)
        } catch {
            logger.error("Subscription request failed: \(error.localizedDescription, privacy: .public)")
            throw ConfigError.networkError(error)
        }

        if let httpResponse = response as? HTTPURLResponse {
            // 优先根据响应头提前拒绝，避免下载大文件
            if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init) {
                try Self.validateSubscriptionSize(bytes: contentLength)
            }

            logger.info("Subscription response status: \(httpResponse.statusCode), bytes: \(data.count)")
            guard (200...299).contains(httpResponse.statusCode) else {
                throw ConfigError.invalidResponse(statusCode: httpResponse.statusCode)
            }
        }

        // 二次校验：实际接收字节也必须在限制内
        try Self.validateSubscriptionSize(bytes: data.count)

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
            // 解码后仍可能超过限制，做一次校验
            try Self.validateSubscriptionSize(bytes: decodedContent.utf8.count)
            logger.info("Subscription content was base64 encoded, decoded length: \(decodedContent.count)")
            content = decodedContent
        }

        return content
    }

    // MARK: - 订阅内容处理

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

    /// 对比新内容与当前文件，判断是否有变化
    private func isContentChanged(_ newConfig: String) -> Bool {
        // URI 列表 → 对比 providers.txt
        if isURIList(newConfig) {
            let providerPath = configDirectory.appendingPathComponent(Self.providerFileName)
            if let existing = try? String(contentsOf: providerPath, encoding: .utf8) {
                return existing != newConfig
            }
            return true // 文件不存在，视为变化
        }
        // YAML 配置 → 对比 config.yaml
        if let existing = try? String(contentsOf: runtimeConfigFile, encoding: .utf8) {
            return existing != newConfig
        }
        return true
    }

    /// 保存订阅内容到磁盘（URI 列表 → providers.txt + config.yaml；YAML → config.yaml）
    private func saveContent(_ rawContent: String, configContent: String) throws {
        if isURIList(rawContent) {
            let providerPath = configDirectory.appendingPathComponent(Self.providerFileName)
            try Data(rawContent.utf8).write(to: providerPath, options: .atomic)
            logger.info("Saved provider file to \(providerPath.path, privacy: .public)")
        }
        try Data(configContent.utf8).write(to: runtimeConfigFile, options: .atomic)
        logger.info("Wrote runtime config to \(self.runtimeConfigFile.path, privacy: .public), size: \(configContent.count)")
    }

    /// 生成最终配置内容
    private func generateConfigContent(from rawContent: String) -> String {
        if isURIList(rawContent) {
            let lineCount = rawContent.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            DaemonLogger.shared.log("CONFIG", "URI 列表 (\(lineCount) 条)，生成 proxy-providers 配置")
            return generateConfigWithProviders()
        }
        DaemonLogger.shared.log("CONFIG", "YAML 配置，直通使用")
        return rawContent
    }

    /// 生成使用 proxy-providers 的完整配置模板
    private func generateConfigWithProviders() -> String {
        """
        \(DefaultRules.baseConfig)
        proxy-providers:
          mysub:
            type: file
            path: \(configDirectory.appendingPathComponent(Self.providerFileName).path)
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
    ///
    /// 支持两种 YAML 格式：
    /// - inline: `- { name: BoostNet, type: select, proxies: [...] }`
    /// - block:  `- name: BoostNet\n    type: select\n    proxies: [...]`
    func parseProxyGroupsOrder() -> [String] {
        guard let content = try? String(contentsOf: runtimeConfigFile, encoding: .utf8) else {
            return []
        }
        return Self.parseProxyGroupsOrder(in: content)
    }

    /// 纯函数版本：直接从 YAML 文本中解析 proxy-groups 顺序（便于测试）
    static func parseProxyGroupsOrder(in yamlContent: String) -> [String] {
        var groups: [String] = []
        var inProxyGroups = false

        let lines = yamlContent.components(separatedBy: .newlines)

        for rawLine in lines {
            // 剥离行内注释（简单的 "#..." 切分足够覆盖常规场景）
            let line: String
            if let hashIdx = rawLine.firstIndex(of: "#") {
                line = String(rawLine[..<hashIdx])
            } else {
                line = rawLine
            }

            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if !inProxyGroups {
                if trimmed == "proxy-groups:" {
                    inProxyGroups = true
                }
                continue
            }

            // 已进入 proxy-groups 段，遇到同级或更外层的 key → 结束
            if !trimmed.hasPrefix("-") && indent == 0 {
                break
            }

            // 只关心列表项起点 "- ..."
            guard trimmed.hasPrefix("-") else { continue }

            // 提取 name（同时支持 inline 和 block 形式）
            if let name = extractGroupName(from: trimmed),
               !groups.contains(name) {
                groups.append(name)
            }
        }

        return groups
    }

    /// 从一个列表项行中提取 group 的 name 字段（纯函数，便于测试）
    /// - inline: `- { name: BoostNet, ... }` → "BoostNet"
    /// - block:  `- name: BoostNet`         → "BoostNet"
    static func extractGroupName(from trimmedLine: String) -> String? {
        // 去掉开头的 "- "
        let body: String
        if trimmedLine.hasPrefix("- ") {
            body = String(trimmedLine.dropFirst(2))
        } else if trimmedLine == "-" {
            body = ""
        } else {
            // "-{..." 或 "-xxx" 之类，紧贴的也当作 inline
            body = String(trimmedLine.dropFirst())
        }

        // inline 格式: { name: xxx, ... }
        if body.hasPrefix("{") {
            return extractInlineName(from: body)
        }

        // block 格式: name: xxx
        if body.hasPrefix("name:") {
            let value = body.dropFirst("name:".count)
                .trimmingCharacters(in: .whitespaces)
            return unquote(value)
        }

        return nil
    }

    /// 从 `{ name: BoostNet, type: ..., proxies: [...] }` 中提取 name（纯函数）
    static func extractInlineName(from inlineBody: String) -> String? {
        guard let nameRange = inlineBody.range(of: "name:") else { return nil }
        let after = inlineBody[nameRange.upperBound...]
        // 找到下一个逗号或右花括号作为结束
        var endIndex = after.endIndex
        for idx in after.indices {
            let ch = after[idx]
            if ch == "," || ch == "}" {
                endIndex = idx
                break
            }
        }
        let raw = String(after[..<endIndex]).trimmingCharacters(in: .whitespaces)
        let unquoted = unquote(raw)
        return unquoted.isEmpty ? nil : unquoted
    }

    /// 去除首尾的单/双引号（纯函数）
    private static func unquote(_ value: String) -> String {
        var v = value
        if (v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2)
            || (v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2) {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }
}

// MARK: - 错误类型

enum ConfigError: LocalizedError {
    case invalidSubscriptionURL
    case invalidResponse(statusCode: Int? = nil)
    case emptySubscription
    case subscriptionBlocked
    case subscriptionTooLarge(declaredBytes: Int)
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
        case .subscriptionTooLarge(let bytes):
            let mb = Double(bytes) / 1_048_576
            return String(format: "订阅内容过大（%.1f MB），已超过 5 MB 安全上限", mb)
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        }
    }
}
