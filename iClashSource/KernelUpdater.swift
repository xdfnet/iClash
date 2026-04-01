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

    /// 检查更新
    func checkForUpdate() async -> Bool {
        guard let url = URL(string: githubAPI) else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                return false
            }

            // 去除 v 前缀
            latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            return latestVersion != mihomoService.kernelVersion
        } catch {
            logger.error("Failed to check for update: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 获取最新版本号 (正式版)
    func fetchLatestVersion() async -> String? {
        guard let url = URL(string: githubAPI) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                return nil
            }

            return tagName
        } catch {
            logger.error("Failed to fetch latest version: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 更新内核
    func updateKernel() async -> KernelUpdateResult {
        // 先获取最新版本信息 (正式版)
        guard let url = URL(string: githubAPI) else {
            return .failed(KernelUpdaterError.invalidURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                return .failed(KernelUpdaterError.invalidResponse)
            }

            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let versionWithV = tagName

            // 查找 darwin-arm64 版本的下载链接
            guard let downloadURLString = findAssetURL(in: assets, version: version),
                  let finalDownloadURL = URL(string: downloadURLString) else {
                return .failed(KernelUpdaterError.downloadURLNotFound)
            }

            // 下载并解压
            try await downloadAndInstallKernel(from: finalDownloadURL)

            // 更新内存中的版本号
            mihomoService.updateKernelVersion(versionWithV)

            return .updated(newVersion: versionWithV)
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

    /// 下载并安装内核
    private func downloadAndInstallKernel(from url: URL) async throws {
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

        // 替换现有内核
        let targetPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/mihomo")

        // 停止当前服务
        mihomoService.stop()

        // 等待进程真正退出
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1秒

        // 替换 bundle 中的内核
        if FileManager.default.fileExists(atPath: targetPath.path) {
            try FileManager.default.removeItem(atPath: targetPath.path)
        }
        try FileManager.default.copyItem(at: mihomoBin, to: targetPath)

        // 清理临时文件
        try? FileManager.default.removeItem(at: tempDir)

        logger.info("Kernel updated successfully")
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
