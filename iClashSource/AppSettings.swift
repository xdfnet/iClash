import Foundation

/// 应用设置（订阅地址等）
/// 注意：此类应在主线程或通过 MainActor 访问，以确保线程安全
@MainActor
final class AppSettings {
    var subscriptionURL: String = ""

    static let subscriptionURLKey = "subscriptionURL"

    /// 加载设置
    static func load() -> AppSettings {
        var settings = AppSettings()
        let defaults = UserDefaults.standard

        if let url = defaults.string(forKey: subscriptionURLKey) {
            settings.subscriptionURL = url
        }

        return settings
    }

    /// 保存设置
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(subscriptionURL, forKey: AppSettings.subscriptionURLKey)
    }
}