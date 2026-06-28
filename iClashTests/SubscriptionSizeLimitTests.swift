import XCTest
@testable import iClash

/// 验证订阅下载的大小限制逻辑
@MainActor
final class SubscriptionSizeLimitTests: XCTestCase {

    func testAcceptsPayloadAtLimit() throws {
        // 等于上限本身应该被允许
        XCTAssertNoThrow(try ConfigManager.validateSubscriptionSize(bytes: ConfigManager.maxSubscriptionBytes))
    }

    func testAcceptsSmallPayload() throws {
        XCTAssertNoThrow(try ConfigManager.validateSubscriptionSize(bytes: 1))
        XCTAssertNoThrow(try ConfigManager.validateSubscriptionSize(bytes: 1_024))
        XCTAssertNoThrow(try ConfigManager.validateSubscriptionSize(bytes: 1_048_576)) // 1 MB
    }

    func testRejectsPayloadAboveLimit() {
        XCTAssertThrowsError(try ConfigManager.validateSubscriptionSize(bytes: ConfigManager.maxSubscriptionBytes + 1)) { error in
            guard case ConfigError.subscriptionTooLarge(let bytes) = error else {
                XCTFail("Expected subscriptionTooLarge, got \(error)")
                return
            }
            XCTAssertEqual(bytes, ConfigManager.maxSubscriptionBytes + 1)
        }
    }

    func testRejectsMassivePayload() {
        XCTAssertThrowsError(try ConfigManager.validateSubscriptionSize(bytes: 100 * 1_048_576)) { error in
            guard case ConfigError.subscriptionTooLarge = error else {
                XCTFail("Expected subscriptionTooLarge, got \(error)")
                return
            }
        }
    }

    func testLimitConstantIs5MB() {
        XCTAssertEqual(ConfigManager.maxSubscriptionBytes, 5 * 1_024 * 1_024)
    }

    func testErrorMessageMentionsSizeLimit() {
        let error = ConfigError.subscriptionTooLarge(declaredBytes: 10 * 1_048_576)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("10.0") || message.contains("10"), "Error should mention the actual size in MB, got: \(message)")
        XCTAssertTrue(message.contains("5") && message.contains("MB"), "Error should mention the 5 MB limit, got: \(message)")
    }
}