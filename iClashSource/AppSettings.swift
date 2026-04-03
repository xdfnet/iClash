import Foundation

/// 应用设置管理
@MainActor
final class AppSettings {
    static let shared = AppSettings()
    static let subscriptionEnvironmentKey = "ICLASH_SUBSCRIPTION_URL"

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let subscriptionURL = "subscriptionURL"
        static let lastUpdateTime = "lastUpdateTime"
    }

    /// 默认订阅地址（仅读取环境变量）
    static var defaultSubscriptionURL: String {
        environmentSubscriptionURL ?? ""
    }

    static var environmentSubscriptionURL: String? {
        let environmentValue = ProcessInfo.processInfo.environment[subscriptionEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let environmentValue, !environmentValue.isEmpty else {
            return nil
        }
        return environmentValue
    }

    /// 当前订阅地址
    var subscriptionURL: String {
        get {
            Self.environmentSubscriptionURL
                ?? defaults.string(forKey: Keys.subscriptionURL)
                ?? Self.defaultSubscriptionURL
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
