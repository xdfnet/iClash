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

    /// 默认订阅地址
    static let defaultSubscriptionURL = "https://boost.hobbyx.cn/d/ddb0b489d10d14ba2d8912b8d30bde03"

    /// 当前订阅地址
    var subscriptionURL: String {
        get {
            defaults.string(forKey: Keys.subscriptionURL) ?? Self.defaultSubscriptionURL
        }
        set {
            defaults.set(newValue, forKey: Keys.subscriptionURL)
        }
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
        subscriptionURL = Self.defaultSubscriptionURL
        lastUpdateTime = nil
    }
}
