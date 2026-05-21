import Foundation

/// 应用设置管理
/// 配置文件 ~/.config/iclash/config.json 优先，UserDefaults 为缓存
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private var configFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/iclash", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    private struct FileConfig: Codable {
        var subscriptionURL: String?
    }

    private enum Keys {
        static let subscriptionURL = "subscriptionURL"
        static let lastUpdateTime = "lastUpdateTime"
    }

    /// 当前订阅地址（配置文件优先，UserDefaults 兜底）
    var subscriptionURL: String {
        get {
            if let fileValue = readFromFile()?.subscriptionURL,
               !fileValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return fileValue
            }
            return (defaults.string(forKey: Keys.subscriptionURL) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedValue.isEmpty {
                defaults.removeObject(forKey: Keys.subscriptionURL)
                removeFromFile()
            } else {
                defaults.set(trimmedValue, forKey: Keys.subscriptionURL)
                writeToFile(url: trimmedValue)
            }
        }
    }

    var hasSubscriptionURL: Bool {
        !subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 上次更新时间
    var lastUpdateTime: Date? {
        get {
            defaults.object(forKey: Keys.lastUpdateTime) as? Date
        }
        set {
            defaults.set(newValue, forKey: Keys.lastUpdateTime)
        }
    }

    private init() {}

    /// 重置为默认设置
    func resetToDefaults() {
        subscriptionURL = ""
        lastUpdateTime = nil
        removeFromFile()
    }

    // MARK: - 配置文件读写

    private func readFromFile() -> FileConfig? {
        guard let data = try? Data(contentsOf: configFileURL),
              let config = try? JSONDecoder().decode(FileConfig.self, from: data) else {
            return nil
        }
        return config
    }

    private func writeToFile(url: String) {
        let config = FileConfig(subscriptionURL: url)
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: configFileURL, options: .atomic)
    }

    private func removeFromFile() {
        try? FileManager.default.removeItem(at: configFileURL)
    }
}
