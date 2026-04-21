import XCTest
@testable import iClash

@MainActor
final class KernelUpdaterTests: XCTestCase {
    private let updater = KernelUpdater.shared

    func testIsCurrentKernelVersionNormalizesVersionFormats() {
        XCTAssertTrue(updater.isCurrentKernelVersion("Mihomo Meta alpha-1.19.1", matching: "v1.19.1"))
        XCTAssertTrue(updater.isCurrentKernelVersion("v1.19.1", matching: "1.19.1"))
        XCTAssertFalse(updater.isCurrentKernelVersion("v1.19.0", matching: "1.19.1"))
    }

    func testGetDownloadURLBuildsCorrectURL() {
        let version = "v1.19.24"
        let expectedArch = updater.preferredArchitecture

        let url = try? updater.getDownloadURL(version: version)

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "github.com")
        XCTAssertEqual(url?.absoluteString, "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-darwin-\(expectedArch)-v1.19.24.gz")
    }

    func testGetDownloadURLHandlesVersionWithoutVPrefix() {
        let expectedArch = updater.preferredArchitecture

        let url = try? updater.getDownloadURL(version: "1.19.24")

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-darwin-\(expectedArch)-v1.19.24.gz")
    }

    func testParseLatestVersionFromHTML() throws {
        let html = #"""
        <a href="/MetaCubeX/mihomo/releases/tag/v1.19.24">v1.19.24</a>
        <a href="/MetaCubeX/mihomo/releases/tag/v1.19.23">v1.19.23</a>
        """#

        let version = try updater.parseLatestVersion(from: html)

        XCTAssertEqual(version, "v1.19.24")
    }

    func testParseLatestVersionPrefersStableOverPrerelease() throws {
        let html = #"""
        <a href="/MetaCubeX/mihomo/releases/tag/Prerelease-Alpha">Prerelease-Alpha</a>
        <a href="/MetaCubeX/mihomo/releases/tag/v1.19.24">v1.19.24</a>
        """#

        let version = try updater.parseLatestVersion(from: html)

        XCTAssertEqual(version, "v1.19.24")
    }
}
