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

    func testGitHubReleaseModelDecoding() throws {
        let json = #"""
        {
            "tag_name": "v1.19.26",
            "assets": [
                {
                    "name": "mihomo-darwin-arm64-v1.19.26.gz",
                    "browser_download_url": "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.26/mihomo-darwin-arm64-v1.19.26.gz"
                }
            ]
        }
        """#

        let data = try XCTUnwrap(json.data(using: .utf8))
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        XCTAssertEqual(release.tagName, "v1.19.26")
        XCTAssertEqual(release.assets?.count, 1)
        XCTAssertEqual(release.assets?.first?.name, "mihomo-darwin-arm64-v1.19.26.gz")
        XCTAssertEqual(release.assets?.first?.browserDownloadURL, "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.26/mihomo-darwin-arm64-v1.19.26.gz")
    }

    func testGitHubReleaseModelDecodingWithoutAssets() throws {
        let json = #"""
        {
            "tag_name": "v1.19.26"
        }
        """#

        let data = try XCTUnwrap(json.data(using: .utf8))
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        XCTAssertEqual(release.tagName, "v1.19.26")
        XCTAssertNil(release.assets)
    }
}
