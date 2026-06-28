import XCTest
@testable import iClash

/// 验证 ConfigManager 对 proxy-groups 的解析能力
///
/// 覆盖两种主流 YAML 格式：
/// - inline: `- { name: BoostNet, type: select, proxies: [...] }`
/// - block:  `- name: BoostNet\n    type: select\n    proxies: [...]`
@MainActor
final class ProxyGroupsParserTests: XCTestCase {

    // MARK: - inline 格式

    func testParsesInlineFormat() {
        let yaml = """
        mixed-port: 7890
        proxies:
          - { name: "HK-1", type: ss, server: hk.example.com, port: 443 }
        proxy-groups:
          - { name: BoostNet, type: select, proxies: [自动选择, DIRECT] }
          - { name: 自动选择, type: url-test, use: [mysub], url: 'http://www.gstatic.com/generate_204' }
        rules:
          - GEOIP,CN,DIRECT
        """

        let groups = ConfigManager.parseProxyGroupsOrder(in: yaml)
        XCTAssertEqual(groups, ["BoostNet", "自动选择"])
    }

    func testInlineFormatPreservesOrder() {
        let yaml = """
        proxy-groups:
          - { name: Z, type: select, proxies: [DIRECT] }
          - { name: A, type: select, proxies: [DIRECT] }
          - { name: M, type: select, proxies: [DIRECT] }
        """

        let groups = ConfigManager.parseProxyGroupsOrder(in: yaml)
        XCTAssertEqual(groups, ["Z", "A", "M"])
    }

    // MARK: - block 格式

    func testParsesBlockFormat() {
        let yaml = """
        mixed-port: 7890
        proxy-groups:
          - name: BoostNet
            type: select
            proxies:
              - 自动选择
              - DIRECT
          - name: 自动选择
            type: url-test
            use:
              - mysub
            url: http://www.gstatic.com/generate_204
            interval: 300
        rules:
          - GEOIP,CN,DIRECT
        """

        let groups = ConfigManager.parseProxyGroupsOrder(in: yaml)
        XCTAssertEqual(groups, ["BoostNet", "自动选择"])
    }

    func testBlockFormatHandlesQuotedNames() {
        let yaml = """
        proxy-groups:
          - name: "Hong Kong"
            type: select
            proxies:
              - DIRECT
          - name: 'United States'
            type: select
            proxies:
              - DIRECT
        """

        let groups = ConfigManager.parseProxyGroupsOrder(in: yaml)
        XCTAssertEqual(groups, ["Hong Kong", "United States"])
    }

    // MARK: - 混合格式

    func testParsesMixedInlineAndBlockFormats() {
        let yaml = """
        proxy-groups:
          - { name: First, type: select, proxies: [DIRECT] }
          - name: Second
            type: select
            proxies:
              - DIRECT
          - { name: Third, type: select, proxies: [DIRECT] }
        """

        let groups = ConfigManager.parseProxyGroupsOrder(in: yaml)
        XCTAssertEqual(groups, ["First", "Second", "Third"])
    }

    // MARK: - 边界条件

    func testReturnsEmptyWhenNoProxyGroupsSection() {
        let yaml = """
        mixed-port: 7890
        proxies:
          - name: direct
            type: direct
        rules:
          - GEOIP,CN,DIRECT
        """

        let groups = ConfigManager.parseProxyGroupsOrder(in: yaml)
        XCTAssertTrue(groups.isEmpty)
    }

    func testHandlesInlineNameWithSpecialCharacters() {
        let yaml = """
        proxy-groups:
          - { name: "🇭🇰 Hong Kong", type: select, proxies: [DIRECT] }
          - { name: 节点1, type: select, proxies: [DIRECT] }
        """

        let groups = ConfigManager.parseProxyGroupsOrder(in: yaml)
        XCTAssertEqual(groups, ["🇭🇰 Hong Kong", "节点1"])
    }

    func testIgnoresCommentLines() {
        let yaml = """
        # 这是顶级注释
        proxy-groups:
          # group 列表
          - { name: BoostNet, type: select, proxies: [DIRECT] }  # 注释1
          - name: Auto
            type: url-test
            # proxies 列表
            proxies:
              - DIRECT
        """

        let groups = ConfigManager.parseProxyGroupsOrder(in: yaml)
        XCTAssertEqual(groups, ["BoostNet", "Auto"])
    }

    func testStopsAtNextTopLevelKey() {
        let yaml = """
        proxy-groups:
          - { name: BoostNet, type: select, proxies: [DIRECT] }
        rules:
          - GEOIP,CN,DIRECT
          - MATCH,DIRECT
        """

        let groups = ConfigManager.parseProxyGroupsOrder(in: yaml)
        XCTAssertEqual(groups, ["BoostNet"])
    }

    func testDeduplicatesRepeatedNames() {
        // 极端情况：同一名字出现两次（解析时只取首次）
        let yaml = """
        proxy-groups:
          - { name: Same, type: select, proxies: [DIRECT] }
          - { name: Same, type: select, proxies: [DIRECT] }
        """

        let groups = ConfigManager.parseProxyGroupsOrder(in: yaml)
        XCTAssertEqual(groups, ["Same"])
    }
}