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
