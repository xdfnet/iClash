import Foundation
import os.log

/// 配置文件管理器
@MainActor
final class ConfigManager {
    static let shared = ConfigManager()

    private let logger = Logger(subsystem: "com.iclash.macos", category: "ConfigManager")
    private let directSession: URLSession
    private let settings = AppSettings.shared

    /// 当前可安全转换为 Mihomo 配置的 URI 协议
    private static let convertibleSchemes = ["anytls", "ss", "shadowsocks"]

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

        content = try normalizeSubscriptionContent(content)

        return content
    }

    func normalizeSubscriptionContent(_ content: String) throws -> String {
        var normalizedContent = content

        switch classifySubscriptionContent(normalizedContent) {
        case .proxyURIList(let entries):
            let unsupportedSchemes = Array(Set(entries.map(\.scheme)).subtracting(Self.convertibleSchemes)).sorted()
            guard unsupportedSchemes.isEmpty else {
                throw ConfigError.unsupportedProxySchemes(unsupportedSchemes)
            }
            logger.info("Detected proxy URI list, generating runtime YAML config")
            normalizedContent = try generateConfigFromUriList(entries)
        case .configFile:
            logger.info("Subscription content is already a config file")
        }

        return normalizedContent
    }

    private enum SubscriptionContentType {
        case proxyURIList([ProxyURIEntry])
        case configFile
    }

    private struct ProxyURIEntry {
        let rawValue: String
        let scheme: String
    }

    private func classifySubscriptionContent(_ content: String) -> SubscriptionContentType {
        let lines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        let uriEntries = lines.compactMap(parseProxyURIEntry(from:))
        if !uriEntries.isEmpty && uriEntries.count == lines.count {
            return .proxyURIList(uriEntries)
        }

        return .configFile
    }

    private func parseProxyURIEntry(from line: String) -> ProxyURIEntry? {
        guard let separatorRange = line.range(of: "://"),
              separatorRange.lowerBound != line.startIndex else {
            return nil
        }

        let scheme = String(line[..<separatorRange.lowerBound]).lowercased()
        guard !scheme.isEmpty,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else {
            return nil
        }

        return ProxyURIEntry(rawValue: line, scheme: scheme)
    }

    /// 从 URI 列表生成完整的配置文件
    private func generateConfigFromUriList(_ entries: [ProxyURIEntry]) throws -> String {
        var proxiesYaml: [String] = []
        var proxyNames: [String] = []

        for entry in entries {
            let proxy = try parseProxyURI(entry)
            proxyNames.append(proxy.name)
            proxiesYaml.append(proxy.yaml)
        }

        guard !proxyNames.isEmpty else {
            throw ConfigError.emptySubscription
        }

        let proxiesSection = proxiesYaml.joined(separator: "\n    ")
        let proxyNamesList = proxyNames.map(yamlQuote).joined(separator: ", ")

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
    private func parseProxyURI(_ entry: ProxyURIEntry) throws -> (name: String, yaml: String) {
        switch entry.scheme {
        case "anytls":
            return try parseAnyTLSURI(entry.rawValue)
        case "ss", "shadowsocks":
            return try parseShadowsocksURI(entry.rawValue)
        default:
            throw ConfigError.unsupportedProxySchemes([entry.scheme])
        }
    }

    private func parseAnyTLSURI(_ uri: String) throws -> (name: String, yaml: String) {
        // 手动解析 URI，避免 URL 组件对密码中特殊字符的截断问题
        let (passwordPart, hostPart, fragment) = try parseAnyTLSURIRaw(uri)

        let host = hostPart.host
        guard !host.isEmpty else {
            throw ConfigError.invalidProxyURI(uri)
        }

        let name = fragment.isEmpty ? "Unknown" : decodeURIComponent(fragment)
        let password = decodeURIComponent(passwordPart)
        guard !password.isEmpty else {
            throw ConfigError.invalidProxyURI(uri)
        }

        let port = hostPart.port
        var sni = ""
        var insecure = false
        var flow = ""
        var udp: Bool?

        if let queryItems = hostPart.queryItems {
            for item in queryItems {
                switch item.name.lowercased() {
                case "sni":
                    sni = item.value ?? ""
                case "insecure":
                    insecure = item.value == "1" || item.value == "true" || item.value == "yes"
                case "flow":
                    flow = item.value ?? ""
                case "udp":
                    if let val = item.value?.lowercased() {
                        udp = (val == "1" || val == "true" || val == "yes")
                    }
                default:
                    break
                }
            }
        }

        var fields = [
            "name: \(yamlQuote(name))",
            "type: anytls",
            "server: \(yamlQuote(host))",
            "port: \(port)",
            "password: \(yamlQuote(password))"
        ]

        if !sni.isEmpty {
            fields.append("sni: \(yamlQuote(sni))")
        }
        if !flow.isEmpty {
            fields.append("flow: \(yamlQuote(flow))")
        }
        fields.append("skip-cert-verify: \(insecure ? "true" : "false")")
        fields.append("udp: \(udp ?? true)")

        return (name, "- { \(fields.joined(separator: ", ")) }")
    }

    /// 手动解析 AnyTLS URI 的各个部分，避免 URL 组件对特殊字符的处理差异
    /// 格式: anytls://password@host:port?params#fragment
    private func parseAnyTLSURIRaw(_ uri: String) throws -> (password: String, host: HostPortQuery, fragment: String) {
        // 去掉 scheme
        let schemeSuffix = "://"
        guard let schemeEnd = uri.range(of: schemeSuffix) else {
            throw ConfigError.invalidProxyURI(uri)
        }
        let remainder = String(uri[schemeEnd.upperBound...])

        // 分离 fragment (#)
        let (withoutFragment, fragment) = {
            if let hashIndex = remainder.firstIndex(of: "#") {
                return (String(remainder[..<hashIndex]), String(remainder[hashIndex...].dropFirst()))
            }
            return (remainder, "")
        }()

        // 分离 password@ 部分: 找第一个 @ 前面的就是 password
        guard let atIndex = withoutFragment.firstIndex(of: "@") else {
            throw ConfigError.invalidProxyURI(uri)
        }
        let password = String(withoutFragment[..<atIndex])
        let hostQueryPart = String(withoutFragment[withoutFragment.index(after: atIndex)...])

        // 用 URLComponents 解析 host:port?query
        let reconstructed = "anytls://\(hostQueryPart)"
        guard let components = URLComponents(string: reconstructed),
              let host = components.host,
              !host.isEmpty else {
            throw ConfigError.invalidProxyURI(uri)
        }

        let port = components.port ?? 443
        let queryItems = components.queryItems

        return (password, HostPortQuery(host: host, port: port, queryItems: queryItems), fragment)
    }

    private struct HostPortQuery {
        let host: String
        let port: Int
        let queryItems: [URLQueryItem]?
    }

    private func parseShadowsocksURI(_ uri: String) throws -> (name: String, yaml: String) {
        guard let entry = parseProxyURIEntry(from: uri),
              entry.scheme == "ss" || entry.scheme == "shadowsocks" else {
            throw ConfigError.invalidProxyURI(uri)
        }

        let contentStart = uri.index(uri.startIndex, offsetBy: entry.scheme.count + 3)
        let content = String(uri[contentStart...])
        let parts = content.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let body = String(parts[0])
        let name = parts.count > 1 ? decodeURIComponent(String(parts[1])) : "Unknown"

        let bodyParts = body.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard bodyParts.count == 1 else {
            throw ConfigError.invalidProxyURI(uri)
        }

        let mainPart = String(bodyParts[0])
        let credentialsAndEndpoint: String
        if let atIndex = mainPart.lastIndex(of: "@") {
            let credentialsPart = String(mainPart[..<atIndex])
            let endpointPart = String(mainPart[mainPart.index(after: atIndex)...])
            let credentials = try parseShadowsocksCredentials(credentialsPart, rawURI: uri)
            credentialsAndEndpoint = "\(credentials.cipher):\(credentials.password)@\(endpointPart)"
        } else {
            credentialsAndEndpoint = try decodeBase64URLSafe(mainPart, rawURI: uri)
        }

        guard let atIndex = credentialsAndEndpoint.lastIndex(of: "@") else {
            throw ConfigError.invalidProxyURI(uri)
        }

        let credentialsPart = String(credentialsAndEndpoint[..<atIndex])
        let endpointPart = String(credentialsAndEndpoint[credentialsAndEndpoint.index(after: atIndex)...])
        let credentials = try parseShadowsocksCredentials(credentialsPart, rawURI: uri)
        let endpoint = try parseEndpoint(endpointPart, rawURI: uri)

        let proxyName = name.isEmpty ? "Unknown" : name
        let yaml = "- { name: \(yamlQuote(proxyName)), type: ss, server: \(yamlQuote(endpoint.host)), port: \(endpoint.port), cipher: \(yamlQuote(credentials.cipher)), password: \(yamlQuote(credentials.password)), udp: true }"
        return (proxyName, yaml)
    }

    private func parseShadowsocksCredentials(_ value: String, rawURI: String) throws -> (cipher: String, password: String) {
        let decodedValue = value.contains(":") ? value : try decodeBase64URLSafe(value, rawURI: rawURI)
        guard let separator = decodedValue.firstIndex(of: ":") else {
            throw ConfigError.invalidProxyURI(rawURI)
        }

        let cipher = String(decodedValue[..<separator])
        let password = String(decodedValue[decodedValue.index(after: separator)...])
        guard !cipher.isEmpty, !password.isEmpty else {
            throw ConfigError.invalidProxyURI(rawURI)
        }

        return (decodeURIComponent(cipher), decodeURIComponent(password))
    }

    private func parseEndpoint(_ value: String, rawURI: String) throws -> (host: String, port: Int) {
        guard let components = URLComponents(string: "http://\(value)"),
              let host = components.host,
              let port = components.port else {
            throw ConfigError.invalidProxyURI(rawURI)
        }

        return (host, port)
    }

    /// 提取代理名称
    private func extractProxyName(from url: URL) -> String {
        let decodedFragment = decodeURIComponent(url.fragment ?? "")
        return decodedFragment.isEmpty ? "Unknown" : decodedFragment
    }

    private func decodeURIComponent(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private func yamlQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func decodeBase64URLSafe(_ value: String, rawURI: String) throws -> String {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }

        guard let data = Data(base64Encoded: normalized, options: .ignoreUnknownCharacters),
              let decodedString = String(data: data, encoding: .utf8),
              !decodedString.isEmpty else {
            throw ConfigError.invalidProxyURI(rawURI)
        }

        return decodedString
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

}

enum ConfigError: LocalizedError {
    case invalidSubscriptionURL
    case invalidResponse(statusCode: Int? = nil)
    case emptySubscription
    case subscriptionBlocked
    case unsupportedProxySchemes([String])
    case invalidProxyURI(String)
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
        case .unsupportedProxySchemes(let schemes):
            return "当前仅支持自动转换 AnyTLS/SS URI 订阅，暂不支持: \(schemes.joined(separator: ", "))"
        case .invalidProxyURI:
            return "订阅中的代理 URI 格式无效或包含暂不支持的参数"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        }
    }
}
