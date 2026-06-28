import XCTest
@testable import iClash

@MainActor
final class ConfigManagerTests: XCTestCase {
    private let configManager = ConfigManager.shared

    private let uriList = """
    anytls://password@hk.example.com:443?sni=cdn.example.com#HK-1
    anytls://password@jp.example.com:8443#JP-1
    """

    private let yamlConfig = """
    mixed-port: 7890
    proxies:
      - name: test
        type: ss
        server: example.com
        port: 8443
        password: secret
    """

    override func setUp() {
        super.setUp()
        // 清理 provider 文件
        let providerPath = configManager.configDirectory
            .appendingPathComponent("providers.txt")
        try? FileManager.default.removeItem(at: providerPath)
    }

    // MARK: - URI 列表 → proxy-providers

    func testNormalizeURIListGeneratesProxyProvidersConfig() throws {
        let output = try configManager.normalizeSubscriptionContent(uriList)

        // 包含 baseConfig 中的关键字段
        XCTAssertTrue(output.contains("mixed-port: 7890"))
        XCTAssertTrue(output.contains("dns:"))

        // 包含 proxy-providers 定义
        XCTAssertTrue(output.contains("proxy-providers:"))
        XCTAssertTrue(output.contains("mysub:"))
        XCTAssertTrue(output.contains("type: file"))
        XCTAssertTrue(output.contains("path: providers.txt"))

        // 包含 proxy-groups 使用 use 引用 provider
        XCTAssertTrue(output.contains("use: [mysub]"))
        XCTAssertTrue(output.contains("name: BoostNet"))
        XCTAssertTrue(output.contains("name: 自动选择"))
        XCTAssertTrue(output.contains("name: 故障转移"))

        // 包含 rules
        XCTAssertTrue(output.contains("rules:"))
        XCTAssertTrue(output.contains("GEOIP,CN,DIRECT"))
    }

    func testNormalizeURIListSavesProviderFile() throws {
        _ = try configManager.normalizeSubscriptionContent(uriList)

        let providerPath = configManager.configDirectory
            .appendingPathComponent("providers.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: providerPath.path))

        let saved = try String(contentsOf: providerPath, encoding: .utf8)
        XCTAssertEqual(saved.trimmingCharacters(in: .whitespacesAndNewlines), uriList)
    }

    // MARK: - YAML 直通

    func testNormalizeYAMLConfigPassThrough() throws {
        let output = try configManager.normalizeSubscriptionContent(yamlConfig)

        // 直通，不做任何转换
        XCTAssertEqual(output, yamlConfig)
    }

    func testNormalizeYAMLConfigDoesNotCreateProviderFile() throws {
        _ = try configManager.normalizeSubscriptionContent(yamlConfig)

        let providerPath = configManager.configDirectory
            .appendingPathComponent("providers.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: providerPath.path))
    }

    // MARK: - 空的/无效内容

    func testNormalizeEmptyContentReturnsEmpty() throws {
        let output = try configManager.normalizeSubscriptionContent("")
        XCTAssertEqual(output, "")
    }

    func testNormalizeMixedContentPassesThrough() throws {
        // 混合内容（非纯 URI）作为 configFile 直通
        let mixed = """
        anytls://password@host:443#test
        mixed-port: 7890
        """
        let output = try configManager.normalizeSubscriptionContent(mixed)
        XCTAssertEqual(output, mixed)
    }
}
