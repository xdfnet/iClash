import Foundation

/// 应用设置（订阅地址等）
struct AppSettings {
    var subscriptionURL: String = ""

    private static let subscriptionURLKey = "subscriptionURL"

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
