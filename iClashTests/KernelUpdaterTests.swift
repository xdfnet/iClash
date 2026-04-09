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

    func testFindAssetURLUsesRequestedArchitecture() {
        let assets: [[String: Any]] = [
            [
                "name": "mihomo-darwin-arm64-v1.19.1.gz",
                "browser_download_url": "https://example.com/arm64"
            ],
            [
                "name": "mihomo-darwin-amd64-v1.19.1.gz",
                "browser_download_url": "https://example.com/amd64"
            ]
        ]

        let arm64URL = updater.findAssetURL(in: assets, version: "1.19.1", preferredArchitecture: "arm64")
        let amd64URL = updater.findAssetURL(in: assets, version: "1.19.1", preferredArchitecture: "amd64")

        XCTAssertEqual(arm64URL, "https://example.com/arm64")
        XCTAssertEqual(amd64URL, "https://example.com/amd64")
    }

    func testFindAssetURLPrefersExactReleaseOverGoVariant() {
        let assets: [[String: Any]] = [
            [
                "name": "mihomo-darwin-arm64-v1.19.1-go120.gz",
                "browser_download_url": "https://example.com/go"
            ],
            [
                "name": "mihomo-darwin-arm64-v1.19.1.gz",
                "browser_download_url": "https://example.com/release"
            ]
        ]

        let selectedURL = updater.findAssetURL(in: assets, version: "1.19.1", preferredArchitecture: "arm64")

        XCTAssertEqual(selectedURL, "https://example.com/release")
    }
}
