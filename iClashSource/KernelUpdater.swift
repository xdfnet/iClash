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

    /// GitHub Releases API
    private let githubAPIURL = "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

    /// 最新版本
    private(set) var latestVersion: String = ""

    private var temporaryUpdateDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mihomo_update")
    }

    private init() {}

    // MARK: - 版本检测

    /// 检查更新（获取最新版本号）
    /// 1. 优先走 GitHub Releases API
    /// 2. API 限频时降级为解析 /releases/latest 重定向 URL
    func checkForUpdate() async throws -> String {
        do {
            return try await checkForUpdateViaAPI()
        } catch KernelUpdaterError.rateLimitExceeded {
            logger.info("GitHub API rate limited, falling back to redirect parsing")
            return try await checkForUpdateViaRedirect()
        } catch {
            logger.warning("GitHub API failed: \(error.localizedDescription, privacy: .public), trying redirect fallback")
            return try await checkForUpdateViaRedirect()
        }
    }

    /// 通过 GitHub Releases API 获取最新版本
    private func checkForUpdateViaAPI() async throws -> String {
        guard let url = URL(string: githubAPIURL) else {
            throw KernelUpdaterError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("iClash/1.5.3", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KernelUpdaterError.invalidResponse
        }

        // 检查 API 频率限制
        if httpResponse.statusCode == 403 || httpResponse.statusCode == 429 {
            let remaining = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining") ?? "0"
            let reset = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap { TimeInterval($0) }
            if remaining == "0", let reset {
                let retryAfter = Date(timeIntervalSince1970: reset).timeIntervalSinceNow
                throw KernelUpdaterError.rateLimitExceeded(retryAfter: max(Int(retryAfter), 0))
            }
            throw KernelUpdaterError.rateLimitExceeded(retryAfter: 60)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("GitHub API returned status \(httpResponse.statusCode)")
            throw KernelUpdaterError.invalidResponse
        }

        let decoder = JSONDecoder()
        let release = try decoder.decode(GitHubRelease.self, from: data)
        let version = release.tagName
        latestVersion = version
        return version
    }

    /// 降级方案：从 /releases/latest 重定向 URL 提取版本号（无频率限制）
    private func checkForUpdateViaRedirect() async throws -> String {
        guard let url = URL(string: "https://github.com/MetaCubeX/mihomo/releases/latest") else {
            throw KernelUpdaterError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = "HEAD"  // 只需要响应头，不需要下载页面

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              let redirectURL = httpResponse.url else {
            throw KernelUpdaterError.invalidResponse
        }

        // 重定向 URL 格式: https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.26
        let urlString = redirectURL.absoluteString
        guard let tagRange = urlString.range(of: "/tag/") else {
            throw KernelUpdaterError.invalidResponse
        }

        let version = String(urlString[tagRange.upperBound...])
        guard !version.isEmpty else {
            throw KernelUpdaterError.invalidResponse
        }

        latestVersion = version
        return version
    }

    // MARK: - 下载与安装

    /// 获取下载链接 - 直接构建 URL
    func getDownloadURL(version: String) throws -> URL {
        let versionWithV = version.hasPrefix("v") ? version : "v\(version)"
        let arch = preferredArchitecture

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

        try? FileManager.default.removeItem(at: tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        logger.info("Starting download from: \(url.absoluteString, privacy: .private(mask: .hash))")
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw KernelUpdaterError.downloadFailed
        }

        try data.write(to: gzPath)

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

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mihomoBin.path)

        logger.info("Kernel downloaded to: \(mihomoBin.path, privacy: .public)")
        return mihomoBin
    }

    /// 安装内核到用户配置目录
    func installKernel(from downloadedPath: URL) throws {
        let targetPath = configManager.configDirectory.appendingPathComponent("mihomo")

        if !FileManager.default.fileExists(atPath: configManager.configDirectory.path) {
            try FileManager.default.createDirectory(at: configManager.configDirectory, withIntermediateDirectories: true)
        }

        if FileManager.default.fileExists(atPath: targetPath.path) {
            try FileManager.default.removeItem(atPath: targetPath.path)
        }
        try FileManager.default.copyItem(at: downloadedPath, to: targetPath)

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

// MARK: - GitHub API 模型

struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

// MARK: - 错误

enum KernelUpdaterError: LocalizedError {
    case invalidURL
    case invalidResponse
    case rateLimitExceeded(retryAfter: Int = 60)
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
        case .rateLimitExceeded(let retryAfter):
            return "GitHub API 请求频率超限，请 \(retryAfter) 秒后再试"
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
