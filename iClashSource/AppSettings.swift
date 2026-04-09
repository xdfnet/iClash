import Foundation

/// 应用设置管理
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let subscriptionURL = "subscriptionURL"
        static let lastUpdateTime = "lastUpdateTime"
    }

    /// 当前订阅地址
    var subscriptionURL: String {
        get {
            (defaults.string(forKey: Keys.subscriptionURL) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedValue.isEmpty {
                defaults.removeObject(forKey: Keys.subscriptionURL)
            } else {
                defaults.set(trimmedValue, forKey: Keys.subscriptionURL)
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
    }
}
