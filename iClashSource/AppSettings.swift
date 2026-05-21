import Foundation

/// 应用设置管理
/// 配置来源：~/.config/iclash/config.json
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private var configFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/iclash", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    private struct FileConfig: Codable {
        var subscriptionURL: String?
    }

    /// 当前订阅地址
    var subscriptionURL: String {
        get {
            readFromFile()?.subscriptionURL?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        set {
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedValue.isEmpty {
                removeFromFile()
            } else {
                writeToFile(url: trimmedValue)
            }
        }
    }

    var hasSubscriptionURL: Bool {
        !subscriptionURL.isEmpty
    }

    private init() {}

    func resetToDefaults() {
        subscriptionURL = ""
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
