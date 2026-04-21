import Foundation
import os.log

/// 内核更新结果
enum KernelUpdateResult {
    case alreadyLatest
    case ready(newVersion: String, downloadedPath: URL)
    case failed(Error)
}

/// 内核更新器
@MainActor
final class KernelUpdater {
    static let shared = KernelUpdater()

    private let logger = Logger(subsystem: "com.iclash.macos", category: "KernelUpdater")

    private let configManager = ConfigManager.shared
    private let mihomoService = MihomoService.shared

    /// GitHub releases 页面
    private let githubReleasesPage = "https://github.com/MetaCubeX/mihomo/releases"

    /// 最新版本
    private(set) var latestVersion: String = ""

    private var temporaryUpdateDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mihomo_update")
    }

    private init() {}

    /// 检查更新（获取最新版本号）- 通过解析 HTML 页面
    func checkForUpdate() async throws -> String {
        guard let url = URL(string: githubReleasesPage) else {
            throw KernelUpdaterError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.15.3 (KHTML, like Gecko) Version/17.0 Safari/605.15.3", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw KernelUpdaterError.invalidResponse
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw KernelUpdaterError.invalidResponse
        }

        // 解析最新版本号 - 查找第一个 releases/tag/ 开头的链接
        let version = try parseLatestVersion(from: html)
        latestVersion = version
        return version
    }

    /// 从 HTML 中解析最新版本号
    func parseLatestVersion(from html: String) throws -> String {
        // 查找 releases/tag/ 后面的版本号
        let pattern = #"releases/tag/(v?[\d]+\.[\d]+\.[\d]+)"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            throw KernelUpdaterError.invalidResponse
        }

        var version = String(html[range])
        if !version.hasPrefix("v") {
            version = "v\(version)"
        }
        return version
    }

    /// 获取下载链接 - 直接构建 URL
    func getDownloadURL(version: String) throws -> URL {
        let versionWithV = version.hasPrefix("v") ? version : "v\(version)"
        let arch = preferredArchitecture

        // 直接构建下载 URL 格式: /MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-darwin-arm64-v1.19.24.gz
        let filename = "mihomo-darwin-\(arch)-\(versionWithV).gz"
        let urlString = "https://github.com/MetaCubeX/mihomo/releases/download/\(versionWithV)/\(filename)"

        guard let url = URL(string: urlString) else {
            throw KernelUpdaterError.invalidURL
        }

        return url
    }

    /// 下载内核到临时目录
    func downloadKernel(from url: URL) async throws -> URL {
        let tempDir = temporaryUpdateDirectory
        let gzPath = tempDir.appendingPathComponent("mihomo.gz")
        let mihomoBin = tempDir.appendingPathComponent("mihomo")

        // 清理临时目录
        try? FileManager.default.removeItem(at: tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 下载
        logger.info("Starting download from: \(url.absoluteString, privacy: .private(mask: .hash))")
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw KernelUpdaterError.downloadFailed
        }

        // 保存 gz 文件
        try data.write(to: gzPath)

        // 用 shell 解压
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "gunzip -dc \(gzPath.path) > \(mihomoBin.path)"]
        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            throw KernelUpdaterError.extractFailed
        }

        guard FileManager.default.fileExists(atPath: mihomoBin.path) else {
            throw KernelUpdaterError.binaryNotFound
        }

        // 设置可执行权限 (r-xr-xr-x)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mihomoBin.path)

        logger.info("Kernel downloaded to: \(mihomoBin.path, privacy: .public)")
        return mihomoBin
    }

    /// 安装内核到用户配置目录（Bundle 在安装后为只读）
    func installKernel(from downloadedPath: URL) throws {
        let targetPath = configManager.configDirectory.appendingPathComponent("mihomo")

        // 确保目录存在
        if !FileManager.default.fileExists(atPath: configManager.configDirectory.path) {
            try FileManager.default.createDirectory(at: configManager.configDirectory, withIntermediateDirectories: true)
        }

        // 替换用户目录中的内核
        if FileManager.default.fileExists(atPath: targetPath.path) {
            try FileManager.default.removeItem(atPath: targetPath.path)
        }
        try FileManager.default.copyItem(at: downloadedPath, to: targetPath)

        // 清理临时文件
        cleanupTemporaryDownload()

        logger.info("Kernel installed successfully")
    }

    func cleanupTemporaryDownload() {
        try? FileManager.default.removeItem(at: temporaryUpdateDirectory)
    }

    func isCurrentKernelVersion(_ currentVersion: String, matching latestVersion: String) -> Bool {
        normalizeVersion(currentVersion) == normalizeVersion(latestVersion)
    }

    /// 准备内核更新（下载完成后由调用方控制安装与重启）
    func updateKernel() async -> KernelUpdateResult {
        do {
            let version = try await checkForUpdate()
            if isCurrentKernelVersion(mihomoService.kernelVersion, matching: version) {
                return .alreadyLatest
            }

            let downloadURL = try getDownloadURL(version: version)
            let downloadedPath = try await downloadKernel(from: downloadURL)

            return .ready(newVersion: version, downloadedPath: downloadedPath)
        } catch {
            cleanupTemporaryDownload()
            return .failed(error)
        }
    }

    var preferredArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "amd64"
        #else
        return "arm64"
        #endif
    }

    func normalizeVersion(_ version: String) -> String? {
        let pattern = #"v?\d+(?:\.\d+)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: version, range: NSRange(version.startIndex..., in: version)),
              let range = Range(match.range, in: version) else {
            return nil
        }

        let extracted = String(version[range])
        return extracted.hasPrefix("v") ? extracted : "v\(extracted)"
    }
}

/// 内核更新错误
enum KernelUpdaterError: LocalizedError {
    case invalidURL
    case invalidResponse
    case rateLimitExceeded
    case downloadURLNotFound
    case downloadFailed
    case extractFailed
    case binaryNotFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的下载地址"
        case .invalidResponse:
            return "无效的服务器响应"
        case .rateLimitExceeded:
            return "GitHub API 请求频率超限，请稍后再试"
        case .downloadURLNotFound:
            return "未找到下载链接"
        case .downloadFailed:
            return "下载失败"
        case .extractFailed:
            return "解压失败"
        case .binaryNotFound:
            return "未找到内核文件"
        }
    }
}
