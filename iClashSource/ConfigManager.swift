import Foundation

/// 配置文件管理器
@MainActor
final class ConfigManager {
    static let shared = ConfigManager()

    let configDirectory: URL
    let runtimeConfigFile: URL

    private var cachedSubscriptionURL: String = ""

    var subscriptionURL: String {
        get { cachedSubscriptionURL }
        set {
            cachedSubscriptionURL = newValue
            let defaults = UserDefaults.standard
            defaults.set(newValue, forKey: AppSettings.subscriptionURLKey)
        }
    }

    /// 重新加载设置
    private func reloadSettings() {
        cachedSubscriptionURL = UserDefaults.standard.string(forKey: AppSettings.subscriptionURLKey) ?? ""
    }

    /// 运行时配置文件是否存在
    var runtimeConfigFileExists: Bool {
        FileManager.default.fileExists(atPath: runtimeConfigFile.path)
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configDirectory = home.appendingPathComponent(".config/iclash", isDirectory: true)
        runtimeConfigFile = configDirectory.appendingPathComponent("config.yaml")
        reloadSettings()
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
        guard !subscriptionURL.isEmpty else {
            throw ConfigError.subscriptionNotConfigured
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

    /// 下载订阅并保存到 config.yaml
    func downloadAndValidateConfig(url: String) async throws -> URL {
        guard URL(string: url) != nil else {
            throw ConfigError.invalidSubscriptionURL
        }

        let content = try await downloadSubscriptionContent(from: url)
        try Data(content.utf8).write(to: runtimeConfigFile, options: .atomic)

        return runtimeConfigFile
    }

    /// 从订阅地址生成运行配置
    func refreshRuntimeConfig() async throws {
        guard !subscriptionURL.isEmpty else {
            throw ConfigError.subscriptionNotConfigured
        }

        let content = try await downloadSubscriptionContent(from: subscriptionURL)
        try Data(content.utf8).write(to: runtimeConfigFile, options: .atomic)
    }

    /// 下载订阅内容并验证
    private func downloadSubscriptionContent(from urlString: String) async throws -> String {
        guard let subscriptionURL = URL(string: urlString) else {
            throw ConfigError.invalidSubscriptionURL
        }

        let request = URLRequest(
            url: subscriptionURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ConfigError.networkError(error)
        }

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw ConfigError.invalidResponse
        }

        guard !data.isEmpty else {
            throw ConfigError.emptySubscription
        }

        let content = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !content.isEmpty else {
            throw ConfigError.emptySubscription
        }

        if content.contains("\"error\"") && content.localizedCaseInsensitiveContains("access denied") {
            throw ConfigError.subscriptionBlocked
        }

        return content
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
        var inProxies = false
        var currentGroupName: String?
        var currentProxies: [String] = []
        var sawDash = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("proxy-groups:") {
                inProxyGroups = true
                sawDash = false
                continue
            }

            if inProxyGroups {
                // 检测 group 开始（单独的 - 后面跟 name:）
                if trimmed == "-" {
                    sawDash = true
                    continue
                }

                if sawDash && trimmed.hasPrefix("name:") {
                    // 保存上一个 group
                    if let name = currentGroupName, !currentProxies.isEmpty {
                        result.append((name: name, proxies: currentProxies))
                    }
                    // 提取新 group 名
                    let name = trimmed.replacingOccurrences(of: "name:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    currentGroupName = name
                    currentProxies = []
                    inProxies = false
                    sawDash = false
                    continue
                }

                if trimmed.hasPrefix("proxies:") {
                    inProxies = true
                    sawDash = false
                    continue
                }

                if inProxies {
                    // 检测 proxy 项
                    if trimmed.hasPrefix("- ") {
                        let proxy = trimmed.replacingOccurrences(of: "- ", with: "")
                            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                        if !proxy.isEmpty {
                            currentProxies.append(proxy)
                        }
                    } else if !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("name:") && !trimmed.hasPrefix("type:") {
                        // 下一个 section 开始
                        inProxies = false
                    }
                }

                // 如果遇到新的 name: 或 type: 在 proxies 之外，重置状态
                if (trimmed.hasPrefix("name:") || trimmed.hasPrefix("type:")) && !inProxies {
                    sawDash = false
                }
            }
        }

        // 保存最后一个 group
        if let name = currentGroupName, !currentProxies.isEmpty {
            result.append((name: name, proxies: currentProxies))
        }

        return result
    }
}

enum ConfigError: LocalizedError {
    case subscriptionNotConfigured
    case invalidSubscriptionURL
    case invalidResponse
    case emptySubscription
    case subscriptionBlocked
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .subscriptionNotConfigured:
            return "订阅地址未配置"
        case .invalidSubscriptionURL:
            return "订阅地址无效"
        case .invalidResponse:
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
