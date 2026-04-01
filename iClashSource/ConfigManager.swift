import Foundation
import os.log

/// 配置文件管理器
@MainActor
final class ConfigManager {
    static let shared = ConfigManager()

    private let logger = Logger(subsystem: "com.iclash.macos", category: "ConfigManager")
    private let directSession: URLSession
    private let settings = AppSettings.shared

    /// 支持的代理协议列表
    private static let supportedSchemes = ["anytls", "ss", "vmess", "vless", "trojan", "hysteria", "hysteria2", "tuic", "wireguard", "shadowsocks"]

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

    /// 确保 GeoIP 数据库存在
    private func ensureGeoIPExists() throws {
        let geoipPath = configDirectory.appendingPathComponent("Country.mmdb")
        guard !FileManager.default.fileExists(atPath: geoipPath.path) else { return }

        // 从 app bundle 复制
        if let resourcePath = Bundle.main.resourceURL {
            let bundleGeoIP = resourcePath.appendingPathComponent("Country.mmdb")
            if FileManager.default.fileExists(atPath: bundleGeoIP.path) {
                try FileManager.default.copyItem(at: bundleGeoIP, to: geoipPath)
            }
        }
    }

    /// 确保基础配置目录存在（在 init 中已自动创建）
    func ensureBaseConfigurationExists() throws {
        // 目录已在 init 中创建
    }

    /// 获取运行时配置文件路径，如果可行会先刷新远程订阅
    func prepareRuntimeConfigFile() async throws -> URL {
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
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 等待 1 秒
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
        // 使用 Mihomo User-Agent 以获取 Base64 编码的订阅内容
        request.setValue("Mihomo/1.18.1", forHTTPHeaderField: "User-Agent")
        logger.debug("Request headers: \(request.allHTTPHeaderFields ?? [:], privacy: .public)")

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
        } else {
            logger.debug("Subscription content is not base64 or does not require decoding")
        }

        // 如果内容是 URI 列表格式（以 anytls://, ss://, vmess:// 等开头）
        // 则生成完整的配置
        if isProxyUriList(content) {
            logger.info("Detected proxy URI list, generating runtime YAML config")
            content = generateConfigFromUriList(uriList: content)
        } else {
            logger.info("Subscription content is already a config file")
        }

        return content
    }

    /// 判断内容是否为代理 URI 列表格式
    private func isProxyUriList(_ content: String) -> Bool {
        let uriPrefixes = ["anytls://", "ss://", "vmess://", "vless://", "trojan://", "shadowsocks://", "hysteria://", "hysteria2://", "tuic://", "wireguard://"]
        let lines = content.components(separatedBy: .newlines)
        // 至少有3行有效的 URI 才认为是 URI 列表
        let uriLines = lines.filter { line in
            uriPrefixes.contains { line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix($0) }
        }
        return uriLines.count >= 3
    }

    /// 从 URI 列表生成完整的配置文件
    private func generateConfigFromUriList(uriList: String) -> String {
        let lines = uriList.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var proxiesYaml: [String] = []
        var proxyNames: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let (name, proxyYaml) = parseProxyUri(trimmed) {
                proxyNames.append(name)
                proxiesYaml.append(proxyYaml)
            }
        }

        let proxiesSection = proxiesYaml.joined(separator: "\n    ")
        let proxyNamesList = proxyNames.map { "'\($0)'" }.joined(separator: ", ")

        return """
        \(DefaultRules.baseConfig)
        proxies:
            \(proxiesSection)
        proxy-groups:
            - { name: BoostNet, type: select, proxies: [自动选择, 故障转移, DIRECT, \(proxyNamesList)] }
            - { name: 自动选择, type: url-test, proxies: [\(proxyNamesList)], url: 'http://www.gstatic.com/generate_204', interval: 300, tolerance: 50 }
            - { name: 故障转移, type: fallback, proxies: [\(proxyNamesList)], url: 'http://www.gstatic.com/generate_204', interval: 300 }
        \(DefaultRules.rulesSection)
        """
    }

    /// 解析代理 URI 并返回 (name, yaml) 元组
    private func parseProxyUri(_ uri: String) -> (name: String, yaml: String)? {
        guard let (scheme, url) = extractSchemeAndURL(from: uri) else {
            return nil
        }

        let name = extractProxyName(from: url)
        let password = extractPassword(from: url, userInfo: url.user ?? "")
        let host = url.host ?? ""
        let port = extractPort(from: url, scheme: scheme)
        let queryParams = extractQueryParameters(from: url)
        let type = normalizeType(scheme)

        let yaml = generateYaml(for: type, name: name, host: host, port: port, password: password, queryParams: queryParams)
        return (name, yaml)
    }

    /// 提取 URL scheme 并验证协议
    private func extractSchemeAndURL(from uri: String) -> (scheme: String, url: URL)? {
        guard let url = URL(string: uri),
              let scheme = url.scheme,
              Self.supportedSchemes.contains(scheme.lowercased()) else {
            return nil
        }
        return (scheme, url)
    }

    /// 提取代理名称
    private func extractProxyName(from url: URL) -> String {
        var name = url.fragment ?? ""
        if let data = name.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(DecodableValue.self, from: data) {
            name = decoded.value
        } else if let decoded = name.removingPercentEncoding {
            name = decoded
        }
        return name.isEmpty ? "Unknown" : name
    }

    /// 提取密码
    private func extractPassword(from url: URL, userInfo: String) -> String {
        url.password ?? userInfo
    }

    /// 提取端口
    private func extractPort(from url: URL, scheme: String) -> Int {
        url.port ?? (scheme == "anytls" ? 443 : 80)
    }

    /// 提取查询参数
    private func extractQueryParameters(from url: URL) -> (sni: String, insecure: Bool) {
        var sni = ""
        var insecure = false
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for item in queryItems {
            switch item.name.lowercased() {
            case "sni":
                sni = item.value ?? ""
            case "insecure":
                insecure = item.value == "1" || item.value == "true"
            default:
                break
            }
        }
        return (sni, insecure)
    }

    /// 标准化协议类型
    private func normalizeType(_ scheme: String) -> String {
        scheme.lowercased() == "shadowsocks" ? "ss" : scheme.lowercased()
    }

    /// 根据协议类型生成 YAML
    private func generateYaml(for type: String, name: String, host: String, port: Int, password: String, queryParams: (sni: String, insecure: Bool)) -> String {
        let baseYaml = "- { name: '\(name)', type: \(type), server: \(host), port: \(port), password: \(password), udp: true }"

        switch type {
        case "ss":
            return baseYaml.replacingOccurrences(of: "cipher: \(type)", with: "cipher: chacha20-ietf-poly1305")
        case "anytls":
            let skipCert = queryParams.insecure ? "true" : "false"
            return "- { name: '\(name)', type: anytls, server: \(host), port: \(port), password: \(password), sni: \(queryParams.sni), skip-cert-verify: \(skipCert), udp: true }"
        default:
            return baseYaml
        }
    }

    /// Base64 解码
    private func base64Decode(_ string: String) throws -> String {
        // 移除可能的 data URI 前缀
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

    private func createDirectoryIfNeeded() throws {
        if !FileManager.default.fileExists(atPath: configDirectory.path) {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        }
    }

    /// 解析 config.yaml 获取 proxy-groups 的顺序
    func parseProxyGroupsOrder() -> [(name: String, proxies: [String])] {
        guard let content = try? String(contentsOf: runtimeConfigFile, encoding: .utf8) else {
            return []
        }

        var result: [(name: String, proxies: [String])] = []
        let lines = content.components(separatedBy: .newlines)

        var inProxyGroups = false
        var currentGroupName: String?
        var currentProxies: [String] = []
        var inInlineFormat = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("proxy-groups:") {
                inProxyGroups = true
                continue
            }

            if !inProxyGroups {
                continue
            }

            // 检测内联格式: - { name: xxx, type: xxx, proxies: [aaa, bbb] }
            if trimmed.hasPrefix("- {") && trimmed.contains("name:") && trimmed.contains("proxies:") {
                // 保存上一个 group
                if let name = currentGroupName, !currentProxies.isEmpty {
                    result.append((name: name, proxies: currentProxies))
                }

                // 解析内联格式
                if let (name, proxies) = parseInlineGroup(trimmed) {
                    currentGroupName = name
                    currentProxies = proxies
                }
                continue
            }

            // 检测多行格式的 group 开始
            if trimmed == "-" || trimmed.hasPrefix("- name:") {
                // 保存上一个 group
                if let name = currentGroupName, !currentProxies.isEmpty {
                    result.append((name: name, proxies: currentProxies))
                }
                currentGroupName = nil
                currentProxies = []
                inInlineFormat = false

                if trimmed.hasPrefix("- name:") {
                    let name = trimmed.replacingOccurrences(of: "- name:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    currentGroupName = name
                }
                continue
            }

            // 多行格式: name: xxx
            if trimmed.hasPrefix("name:") && currentGroupName == nil {
                let name = trimmed.replacingOccurrences(of: "name:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                currentGroupName = name
                continue
            }

            // 多行格式: proxies: 开始
            if trimmed.hasPrefix("proxies:") {
                if trimmed.hasPrefix("proxies: [") && trimmed.contains("]") {
                    // 内联数组格式: proxies: [aaa, bbb]
                    let arrayContent = extractArrayContent(trimmed)
                    currentProxies = parseProxyArray(arrayContent)
                } else if trimmed == "proxies:" || trimmed == "proxies:" {
                    // 多行数组开始
                    inInlineFormat = true
                }
                continue
            }

            // 多行格式: - xxx
            if inInlineFormat && trimmed.hasPrefix("- ") {
                let proxy = trimmed.replacingOccurrences(of: "- ", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if !proxy.isEmpty {
                    currentProxies.append(proxy)
                }
                continue
            }

            // 检测多行数组结束
            if inInlineFormat && !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("name:") && !trimmed.hasPrefix("type:") {
                inInlineFormat = false
            }
        }

        // 保存最后一个 group
        if let name = currentGroupName, !currentProxies.isEmpty {
            result.append((name: name, proxies: currentProxies))
        }

        return result
    }

    /// 解析内联格式 group: - { name: xxx, type: xxx, proxies: [aaa, bbb] }
    private func parseInlineGroup(_ line: String) -> (name: String, proxies: [String])? {
        // 提取 name
        var name = ""
        if let nameRange = line.range(of: "name:") {
            let afterName = line[nameRange.upperBound...]
            if let commaRange = afterName.firstIndex(of: ",") {
                name = String(afterName[..<commaRange]).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
        }

        // 提取 proxies 数组
        var proxies: [String] = []
        if let proxiesRange = line.range(of: "proxies:") {
            let afterProxies = line[proxiesRange.upperBound...]
            if let bracketStart = afterProxies.firstIndex(of: "["),
               let bracketEnd = afterProxies.lastIndex(of: "]") {
                let arrayContent = String(afterProxies[bracketStart...bracketEnd])
                let extracted = extractArrayContent("proxies: \(arrayContent)")
                proxies = parseProxyArray(extracted)
            }
        }

        guard !name.isEmpty else { return nil }
        return (name, proxies)
    }

    /// 从 "proxies: [xxx, yyy]" 格式中提取数组内容
    private func extractArrayContent(_ line: String) -> String {
        if let bracketStart = line.firstIndex(of: "["),
           let bracketEnd = line.lastIndex(of: "]") {
            return String(line[bracketStart...bracketEnd])
        }
        return ""
    }

    /// 解析 proxy 数组字符串 [xxx, yyy, zzz]
    private func parseProxyArray(_ arrayString: String) -> [String] {
        var result: [String] = []
        let content = arrayString.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        // 按逗号分割
        var current = ""
        var depth = 0
        var inQuote = false

        for char in content {
            if char == "'" || char == "\"" {
                inQuote.toggle()
            } else if char == "[" || char == "]" {
                depth += (char == "[" ? 1 : -1)
            } else if char == "," && depth == 0 && !inQuote {
                let proxy = current.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if !proxy.isEmpty {
                    result.append(proxy)
                }
                current = ""
                continue
            }
            current.append(char)
        }

        // 最后一个
        let lastProxy = current.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        if !lastProxy.isEmpty {
            result.append(lastProxy)
        }

        return result
    }

    /// 用于 URL 解码的辅助类型
    private struct DecodableValue: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            value = try container.decode(String.self)
        }
    }
}

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
