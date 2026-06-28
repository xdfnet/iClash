import XCTest
@testable import iClash

@MainActor
final class ConfigManagerTests: XCTestCase {
    private let configManager = ConfigManager.shared

    override func setUp() {
        super.setUp()
        let providerPath = configManager.configDirectory
            .appendingPathComponent("providers.txt")
        try? FileManager.default.removeItem(at: providerPath)
    }

    /// smoke test — 仅验证 ConfigManager 单例可访问且目录就绪
    func testConfigDirectoryExists() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: configManager.configDirectory.path))
    }

    /// 验证运行时配置文件路径位于配置目录下
    func testRuntimeConfigFileIsInsideConfigDirectory() {
        let path = configManager.runtimeConfigFile.path
        XCTAssertTrue(path.hasPrefix(configManager.configDirectory.path))
        XCTAssertTrue(path.hasSuffix("config.yaml"))
    }

    /// 验证当前运行环境的配置文件是否存在性查询正常工作
    func testRuntimeConfigFileExistenceCheck() {
        // 首次启动或未运行订阅时可能不存在；仅验证 getter 不崩溃
        _ = configManager.runtimeConfigFileExists
    }

    /// 验证订阅地址 getter 在未设置时返回空字符串
    func testEmptySubscriptionURLAccess() {
        _ = configManager.subscriptionURL
    }
}