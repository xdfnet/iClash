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
    private let mihomoService = MihomoService.shared
    private let configManager = ConfigManager.shared
    private let proxyManager = ProxyManager.shared
    private let logger = Logger(subsystem: "com.iclash.macos", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? configManager.ensureBaseConfigurationExists()
        setupMenu()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mihomoStatusChanged),
            name: NSNotification.Name("MihomoStatusChanged"),
            object: nil
        )

        // 检查配置是否存在，不存在则先下载（不自动启动代理）
        Task {
            do {
                if !configManager.runtimeConfigFileExists {
                    _ = try await configManager.downloadAndValidateConfig(url: configManager.subscriptionURL)
                }
            } catch {
                showError("初始化配置失败: \(error.localizedDescription)")
            }
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

    func toggleProxy() {
        Task {
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
                    // 更新成功，停内核 → 启动内核
                    self?.mihomoService.stop()
                    Task {
                        try? await self?.mihomoService.start()
                        await MainActor.run {
                            self?.statusBarController.updateStatusIcon(isRunning: self?.mihomoService.isRunning ?? false)
                            let alert = NSAlert()
                            alert.messageText = "内核更新成功"
                            alert.informativeText = "已更新到 v\(newVersion)，已自动启动"
                            alert.alertStyle = .informational
                            alert.addButton(withTitle: "确定")
                            alert.runModal()
                        }
                    }

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
