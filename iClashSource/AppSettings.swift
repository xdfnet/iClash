import Foundation

/// 应用设置管理
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let subscriptionURL = "subscriptionURL"
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
        !subscriptionURL.isEmpty
    }

    private init() {}
}
