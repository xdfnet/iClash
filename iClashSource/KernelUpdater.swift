import Foundation
import os.log

/// 内核更新结果
enum KernelUpdateResult {
    case alreadyLatest
    case updated(newVersion: String)
    case failed(Error)
}

/// 内核更新器
@MainActor
final class KernelUpdater {
    static let shared = KernelUpdater()

    private let logger = Logger(subsystem: "com.iclash.macos", category: "KernelUpdater")

    private let configManager = ConfigManager.shared
    private let mihomoService = MihomoService.shared

    /// GitHub API 获取最新 release (正式版)
    private let githubAPI = "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

    /// 最新版本
    private(set) var latestVersion: String = ""

    private init() {}

    /// 检查更新（获取最新版本号）
    func checkForUpdate() async throws -> String {
        guard let url = URL(string: githubAPI) else {
            throw KernelUpdaterError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            throw KernelUpdaterError.invalidResponse
        }

        return tagName.hasPrefix("v") ? tagName : "v\(tagName)"
    }

    /// 获取下载链接
    func getDownloadURL(version: String) async throws -> URL {
        guard let url = URL(string: githubAPI) else {
            throw KernelUpdaterError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else {
            throw KernelUpdaterError.invalidResponse
        }

        let versionWithoutV = version.hasPrefix("v") ? String(version.dropFirst()) : version
        guard let downloadURLString = findAssetURL(in: assets, version: versionWithoutV),
              let downloadURL = URL(string: downloadURLString) else {
            throw KernelUpdaterError.downloadURLNotFound
        }

        return downloadURL
    }

    /// 下载内核到临时目录
    func downloadKernel(from url: URL) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mihomo_update")
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
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mihomo_update")
        try? FileManager.default.removeItem(at: tempDir)

        logger.info("Kernel installed successfully")
    }

    /// 更新内核（由调用方控制停止/启动）
    func updateKernel() async -> KernelUpdateResult {
        do {
            // 检查版本
            let version = try await checkForUpdate()

            // 获取下载链接
            let downloadURL = try await getDownloadURL(version: version)

            // 下载
            let downloadedPath = try await downloadKernel(from: downloadURL)

            // 安装
            try installKernel(from: downloadedPath)

            // 更新内存中的版本号
            mihomoService.updateKernelVersion(version)

            return .updated(newVersion: version)
        } catch {
            return .failed(error)
        }
    }

    /// 在 GitHub assets 中查找匹配的下载链接
    private func findAssetURL(in assets: [[String: Any]], version: String) -> String? {
        // 优先查找精确版本且不带 go 的 darwin-arm64 版本
        for asset in assets {
            guard let name = asset["name"] as? String,
                  name.hasPrefix("mihomo-darwin-arm64-"),
                  name.hasSuffix(".gz"),
                  name.hasPrefix("mihomo-darwin-arm64-v\(version).gz"),
                  !name.contains("go") else {
                continue
            }
            return asset["browser_download_url"] as? String
        }

        // 如果没找到，尝试查找任意匹配的 darwin-arm64 版本
        for asset in assets {
            guard let name = asset["name"] as? String,
                  name.hasPrefix("mihomo-darwin-arm64-"),
                  name.contains("-\(version).gz") else {
                continue
            }
            return asset["browser_download_url"] as? String
        }

        return nil
    }
}

/// 内核更新错误
enum KernelUpdaterError: LocalizedError {
    case invalidURL
    case invalidResponse
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
