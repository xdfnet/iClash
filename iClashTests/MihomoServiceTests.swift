import XCTest
@testable import iClash

@MainActor
final class MihomoServiceTests: XCTestCase {
    private let service = MihomoService.shared
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MihomoServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testResolveMihomoPathPrefersUserInstalledKernel() throws {
        let bundleMihomo = temporaryDirectory.appendingPathComponent("bundle-mihomo")
        let configMihomo = temporaryDirectory.appendingPathComponent("config-mihomo")
        try createExecutable(at: bundleMihomo)
        try createExecutable(at: configMihomo)

        let selectedPath = try service.resolveMihomoPath(bundleMihomo: bundleMihomo, configMihomo: configMihomo)

        XCTAssertEqual(selectedPath, configMihomo)
    }

    func testResolveMihomoPathBootstrapsUserKernelFromBundleWhenMissing() throws {
        let bundleMihomo = temporaryDirectory.appendingPathComponent("bundle-mihomo")
        let configMihomo = temporaryDirectory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("config-mihomo")
        try createExecutable(at: bundleMihomo)

        let selectedPath = try service.resolveMihomoPath(bundleMihomo: bundleMihomo, configMihomo: configMihomo)

        XCTAssertEqual(selectedPath, configMihomo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configMihomo.path))
        XCTAssertEqual(try String(contentsOf: configMihomo), try String(contentsOf: bundleMihomo))
    }

    func testResolveMihomoPathRepairsUserKernelFromBundleWhenInvalid() throws {
        let bundleMihomo = temporaryDirectory.appendingPathComponent("bundle-mihomo")
        let configMihomo = temporaryDirectory.appendingPathComponent("config-mihomo")
        try createExecutable(at: bundleMihomo)
        try FileManager.default.createDirectory(at: configMihomo, withIntermediateDirectories: true)

        let selectedPath = try service.resolveMihomoPath(bundleMihomo: bundleMihomo, configMihomo: configMihomo)

        XCTAssertEqual(selectedPath, configMihomo)
        XCTAssertEqual(try String(contentsOf: configMihomo), try String(contentsOf: bundleMihomo))
    }

    private func createExecutable(at url: URL) throws {
        let content = "#!/bin/sh\nexit 0\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
