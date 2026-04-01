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
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusBarController = StatusBarController()
    private var menuController: MenuController?
    private let settingsWindowController = SettingsWindowController()
    private let mihomoService = MihomoService.shared
    private let configManager = ConfigManager.shared
    private let proxyManager = ProxyManager.shared
    private let logger = Logger(subsystem: "com.iclash.macos", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? configManager.ensureBaseConfigurationExists()
        setupMenu()

        if configManager.runtimeConfigFileExists {
            startProxyOnLaunch()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mihomoStatusChanged),
            name: NSNotification.Name("MihomoStatusChanged"),
            object: nil
        )
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

    private func startProxyOnLaunch() {
        Task {
            do {
                try await mihomoService.start()
                await mihomoService.fetchKernelVersion()
                await proxyManager.refreshProxyList()
                statusBarController.updateStatusIcon(isRunning: true)
                // 刷新菜单以显示代理列表
                if let menu = menuController?.buildMenu() {
                    statusBarController.setMenu(menu)
                }
            } catch {
                showError("启动代理失败: \(error.localizedDescription)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mihomoService.stop()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "错误"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
}

// MARK: - MenuControllerDelegate

extension AppDelegate: MenuControllerDelegate {
    func menuWillOpen() {
        Task {
            await proxyManager.refreshProxyList()
            if let menu = menuController?.buildMenu() {
                statusBarController.setMenu(menu)
            }
        }
    }

    func menuNeedsUpdate() {
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

    func openSettings() {
        settingsWindowController.delegate = self
        settingsWindowController.showWindow()
    }

    func updateKernel() {
        Task { [weak self] in
            let result = await KernelUpdater.shared.updateKernel()
            await MainActor.run {
                switch result {
                case .alreadyLatest:
                    let alert = NSAlert()
                    alert.messageText = "内核更新"
                    alert.informativeText = "当前已是最新稳定版"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "确定")
                    alert.runModal()

                case .updated(let newVersion):
                    // 更新成功，提示用户
                    self?.mihomoService.stop()
                    let alert = NSAlert()
                    alert.messageText = "内核更新成功"
                    alert.informativeText = "已更新到 v\(newVersion)，请重启应用"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "确定")
                    alert.runModal()

                case .failed(let error):
                    self?.showError("更新失败: \(error.localizedDescription)")
                }
            }
        }
    }

    func quitApp() {
        mihomoService.stop()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - SettingsWindowDelegate

extension AppDelegate: SettingsWindowDelegate {
    func saveSettings(url: String) {
        Task {
            do {
                _ = try await configManager.downloadAndValidateConfig(url: url)
                configManager.subscriptionURL = url
                mihomoService.stop()
                try await mihomoService.start()
                await proxyManager.refreshProxyList()
                statusBarController.updateStatusIcon(isRunning: true)
            } catch {
                showError("\(error.localizedDescription)")
            }
        }
    }
}
