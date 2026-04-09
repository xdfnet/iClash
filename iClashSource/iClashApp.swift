import Cocoa
import SwiftUI
import os.log

@main
struct iClashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("订阅设置...") {
                    NotificationCenter.default.post(name: .openSubscriptionSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusBarController = StatusBarController()
    private var menuController: MenuController?
    private let appSettings = AppSettings.shared
    private let mihomoService = MihomoService.shared
    private let configManager = ConfigManager.shared
    private let proxyManager = ProxyManager.shared
    private let logger = Logger(subsystem: "com.iclash.macos", category: "AppDelegate")
    private let subscriptionSettingsWindowController = SubscriptionSettingsWindowController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? configManager.ensureBaseConfigurationExists()
        setupMenu()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mihomoStatusChanged),
            name: NSNotification.Name("MihomoStatusChanged"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(subscriptionSettingsDidSave(_:)),
            name: .subscriptionSettingsDidSave,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSubscriptionSettingsWindow),
            name: .openSubscriptionSettings,
            object: nil
        )

        guard appSettings.hasSubscriptionURL else {
            statusBarController.updateStatusIcon(isRunning: false)
            return
        }

        Task {
            await startServiceIfConfigured(showErrorAlert: true)
        }
    }

    private func setupMenu() {
        menuController = MenuController(delegate: self)
        if let menu = menuController?.buildMenu() {
            statusBarController.setMenu(menu)
        }
    }

    @objc private func mihomoStatusChanged() {
        statusBarController.updateStatusIcon(isRunning: mihomoService.isRunning)
    }

    @objc private func subscriptionSettingsDidSave(_ notification: Notification) {
        let savedURL = (notification.userInfo?["subscriptionURL"] as? String) ?? appSettings.subscriptionURL
        Task {
            await applySubscriptionChange(savedURL, showErrorAlert: true)
        }
    }

    @objc private func openSubscriptionSettingsWindow() {
        subscriptionSettingsWindowController.present()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 不自动关闭代理，由用户手动控制
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "错误"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    private func refreshMenu() {
        if let menu = menuController?.buildMenu() {
            statusBarController.setMenu(menu)
        }
    }

    private func startServiceIfConfigured(showErrorAlert: Bool) async {
        await applySubscriptionChange(appSettings.subscriptionURL, showErrorAlert: showErrorAlert)
    }

    private func applySubscriptionChange(_ subscriptionURL: String, showErrorAlert: Bool) async {
        let trimmedURL = subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty else {
            let proxyWasEnabled = mihomoService.isSystemProxyEnabled()
            if proxyWasEnabled {
                try? mihomoService.setSystemProxy(enabled: false)
            }
            if mihomoService.isRunning {
                mihomoService.stop()
            }
            proxyManager.reset()
            statusBarController.updateStatusIcon(isRunning: false)
            refreshMenu()
            return
        }

        let proxyWasEnabled = mihomoService.isSystemProxyEnabled()
        if proxyWasEnabled {
            try? mihomoService.setSystemProxy(enabled: false)
        }
        if mihomoService.isRunning {
            mihomoService.stop()
        }
        proxyManager.reset()

        do {
            _ = try await configManager.downloadAndValidateConfig(url: trimmedURL)
            try await mihomoService.start()
            if proxyWasEnabled {
                try? mihomoService.setSystemProxy(enabled: true)
            }
            statusBarController.updateStatusIcon(isRunning: true)

            async let version: () = mihomoService.fetchKernelVersion()
            async let proxies: () = proxyManager.refreshProxyList()
            _ = await (version, proxies)
        } catch {
            statusBarController.updateStatusIcon(isRunning: false)
            if showErrorAlert {
                showError("启动失败: \(error.localizedDescription)")
            }
        }

        refreshMenu()
    }
}

// MARK: - MenuControllerDelegate

extension AppDelegate: MenuControllerDelegate {
    func menuWillOpen() {
        if let menu = menuController?.buildMenu() {
            statusBarController.setMenu(menu)
        }
    }

    func selectProxy(name: String, in group: String) {
        Task {
            do {
                try await proxyManager.selectProxy(name: name, in: group)
                if let menu = menuController?.buildMenu() {
                    statusBarController.setMenu(menu)
                }
            } catch {
                showError("切换节点失败: \(error.localizedDescription)")
            }
        }
    }

    func toggleProxy() {
        Task {
            guard appSettings.hasSubscriptionURL else {
                openSettings()
                return
            }
            let isCurrentlyEnabled = mihomoService.isSystemProxyEnabled()
            if isCurrentlyEnabled {
                // 停止代理：只清除系统代理设置
                try? mihomoService.setSystemProxy(enabled: false)
            } else {
                // 启动代理：只设置系统代理
                try? mihomoService.setSystemProxy(enabled: true)
            }
            if let menu = menuController?.buildMenu() {
                statusBarController.setMenu(menu)
            }
        }
    }

    func openSettings() {
        openSubscriptionSettingsWindow()
    }

    func updateKernel() {
        Task { [weak self] in
            guard let self else { return }
            let coordinator = KernelUpdateCoordinator(service: self.mihomoService, updater: KernelUpdater.shared)
            let result = await coordinator.performUpdate()

            await MainActor.run {
                switch result {
                case .alreadyLatest:
                    let alert = NSAlert()
                    alert.messageText = "内核更新"
                    alert.informativeText = "当前已是最新稳定版"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "确定")
                    alert.runModal()

                case .updated(let newVersion, let restarted):
                    self.statusBarController.updateStatusIcon(isRunning: self.mihomoService.isRunning)
                    let alert = NSAlert()
                    alert.messageText = "内核更新成功"
                    alert.informativeText = restarted
                        ? "已更新到 \(newVersion)，已自动重启"
                        : "已更新到 \(newVersion)"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "确定")
                    alert.runModal()

                case .failed(let error):
                    self.statusBarController.updateStatusIcon(isRunning: self.mihomoService.isRunning)
                    self.showError("更新失败: \(error.localizedDescription)")
                }
            }
        }
    }

    func quitApp() {
        mihomoService.stop() // 停止内核
        try? mihomoService.setSystemProxy(enabled: false) // 关闭系统代理
        NSApplication.shared.terminate(nil) // 退出应用
    }
}
