import XCTest
@testable import iClash

@MainActor
final class ConfigManagerTests: XCTestCase {
    private let configManager = ConfigManager.shared

    func testNormalizeSubscriptionContentConvertsAnyTLSURIList() throws {
        let subscription = [
            "anytls://password1@hk.example.com:443?sni=cdn.example.com#HK-1",
            "anytls://password2@jp.example.com:8443#JP-1"
        ].joined(separator: "\n")

        let output = try configManager.normalizeSubscriptionContent(subscription)

        XCTAssertTrue(output.contains("type: anytls"))
        XCTAssertTrue(output.contains("name: 'HK-1'"))
        XCTAssertTrue(output.contains("server: 'hk.example.com'"))
        XCTAssertTrue(output.contains("sni: 'cdn.example.com'"))
        XCTAssertTrue(output.contains("name: 'JP-1'"))
        // 默认 udp: true
        XCTAssertTrue(output.contains("udp: true"))
    }

    func testAnyTLSWithFlowAndUDPOverride() throws {
        let subscription = [
            "anytls://password@sg.example.com:443?flow=xtls-rprx-vision&udp=false&sni=cloud.sg.example.com#SG"
        ].joined(separator: "\n")

        let output = try configManager.normalizeSubscriptionContent(subscription)

        XCTAssertTrue(output.contains("flow: 'xtls-rprx-vision'"))
        XCTAssertTrue(output.contains("udp: false"))
        XCTAssertTrue(output.contains("sni: 'cloud.sg.example.com'"))
        XCTAssertTrue(output.contains("name: 'SG'"))
    }

    func testAnyTLSWithSpecialCharsInPassword() throws {
        // 密码包含 @ : / 等特殊字符
        let subscription = [
            "anytls://p%40ss%3Aword%2Ftest@special.example.com:443?sni=test.example.com#SpecialPass"
        ].joined(separator: "\n")

        let output = try configManager.normalizeSubscriptionContent(subscription)

        XCTAssertTrue(output.contains("name: 'SpecialPass'"))
        // 解码后的密码: p@ss:word/test
        XCTAssertTrue(output.contains("password: 'p@ss:word/test'"))
    }

    func testAnyTLSWithoutFragmentUsesDefaultName() throws {
        let subscription = [
            "anytls://mypassword@us.example.com:443?sni=us.example.com"
        ].joined(separator: "\n")

        let output = try configManager.normalizeSubscriptionContent(subscription)

        // 没有 #fragment 时 name 应为 Unknown
        XCTAssertTrue(output.contains("name: 'Unknown'"))
    }

    func testAnyTLSInsecureOn() throws {
        let subscription = [
            "anytls://password@insecure.example.com:443?insecure=1#InsecureNode"
        ].joined(separator: "\n")

        let output = try configManager.normalizeSubscriptionContent(subscription)

        XCTAssertTrue(output.contains("skip-cert-verify: true"))
    }

    func testAnyTLSMissingPasswordThrows() throws {
        let subscription = "anytls://@host.com:443?sni=test#NoPass"
        XCTAssertThrowsError(try configManager.normalizeSubscriptionContent(subscription))
    }

    func testAnyTLSUDPExplicitTrue() throws {
        let subscription = [
            "anytls://password@udp-on.example.com:443?udp=yes#UDPOn"
        ].joined(separator: "\n")

        let output = try configManager.normalizeSubscriptionContent(subscription)

        XCTAssertTrue(output.contains("udp: true"))
    }

    func testAnyTLSUDPExplicitFalse() throws {
        let subscription = [
            "anytls://password@udp-off.example.com:443?udp=0#UDPOff"
        ].joined(separator: "\n")

        let output = try configManager.normalizeSubscriptionContent(subscription)

        XCTAssertTrue(output.contains("udp: false"))
    }

    func testNormalizeSubscriptionContentConvertsShadowsocksURIListWithCipher() throws {
        let subscription = [
            "ss://YWVzLTI1Ni1nY206c2VjcmV0QDEyNy4wLjAuMTo4Mzg4#SS-1"
        ].joined(separator: "\n")

        let output = try configManager.normalizeSubscriptionContent(subscription)

        XCTAssertTrue(output.contains("type: ss"))
        XCTAssertTrue(output.contains("cipher: 'aes-256-gcm'"))
        XCTAssertTrue(output.contains("password: 'secret'"))
        XCTAssertTrue(output.contains("server: '127.0.0.1'"))
        XCTAssertTrue(output.contains("port: 8388"))
    }

    func testNormalizeSubscriptionContentRejectsUnsupportedProxyScheme() {
        let subscription = "vmess://eyJhZGQiOiJ2bWVzcy5leGFtcGxlLmNvbSJ9"

        XCTAssertThrowsError(try configManager.normalizeSubscriptionContent(subscription)) { error in
            guard case ConfigError.unsupportedProxySchemes(let schemes) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(schemes, ["vmess"])
        }
    }
}
