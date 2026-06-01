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

/// 委托代理 — 管理菜单栏图标 + 事件分发，编排逻辑委托给 AppCoordinator
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - 状态栏
    private var statusBarItem: NSStatusItem?
    private var menuController: MenuController?

    private let appState = AppState.shared
    private let coordinator = AppCoordinator.shared
    private let mihomoService = MihomoService.shared
    private let configManager = ConfigManager.shared
    private let appSettings = AppSettings.shared
    private let logger = Logger(subsystem: "com.iclash.macos", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? configManager.ensureBaseConfigurationExists()
        setupStatusBar()
        setupMenu()

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

        Task {
            await coordinator.autoStart()
            self.syncUI()
        }
    }

    // MARK: - 状态栏

    private func setupStatusBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusBarItem?.button {
            updateStatusIcon(isRunning: false)
            button.imagePosition = .imageOnly
        }
    }

    private func updateStatusIcon(isRunning: Bool) {
        guard let button = statusBarItem?.button else { return }
        let symbolName = isRunning ? "chart.bar.fill" : "chart.bar"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "iClash") {
            image.isTemplate = true
            button.image = image
        }
        button.title = ""
    }

    // MARK: - 菜单

    private func setupMenu() {
        menuController = MenuController(
            delegate: self,
            coordinator: coordinator,
            appState: appState
        )
        rebuildMenu()
    }

    /// 重新构建并刷新菜单
    private func rebuildMenu() {
        if let menu = menuController?.buildMenu() {
            statusBarItem?.menu = menu
        }
    }

    private func syncUI() {
        updateStatusIcon(isRunning: appState.isRunning)
        rebuildMenu()
    }

    // MARK: - 事件处理

    @objc private func subscriptionSettingsDidSave(_ notification: Notification) {
        let savedURL = (notification.userInfo?["subscriptionURL"] as? String) ?? appSettings.subscriptionURL
        Task {
            await coordinator.applySubscription(url: savedURL)
            self.syncUI()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.prepareForQuit()
    }

    // MARK: - 弹窗

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "错误"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    @objc private func openSubscriptionSettingsWindow() {
        SubscriptionSettingsWindow.shared.present()
    }

    private func showInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
}

// MARK: - MenuControllerDelegate

extension AppDelegate: MenuControllerDelegate {
    func menuWillOpen() {
        rebuildMenu()
    }

    func selectProxy(name: String, in group: String) {
        Task {
            await coordinator.selectProxy(name: name, in: group)
            self.rebuildMenu()
        }
    }

    func toggleProxy() {
        coordinator.toggleProxy()
        syncUI()
    }

    func openSettings() {
        openSubscriptionSettingsWindow()
    }

    func updateKernel() {
        Task { [weak self] in
            guard let self else { return }
            let result = await self.coordinator.updateKernel()

            await MainActor.run {
                switch result {
                case .alreadyLatest:
                    self.showInfo(title: "内核更新", message: "当前已是最新稳定版")

                case .updated(let newVersion, let restarted):
                    let msg = restarted
                        ? "已更新到 \(newVersion)，已自动重启"
                        : "已更新到 \(newVersion)"
                    self.showInfo(title: "内核更新成功", message: msg)

                case .failed(let error):
                    self.showError("更新失败: \(error.localizedDescription)")
                }
            }
            self.syncUI()
        }
    }

    func quitApp() {
        coordinator.prepareForQuit()
        NSApplication.shared.terminate(nil)
    }

    func fetchLatestVersion() async -> String {
        await coordinator.fetchLatestVersion()
    }

    func canOfferUpdate() async -> Bool {
        let latest = await coordinator.fetchLatestVersion()
        guard latest != "获取失败" else { return false }
        return !KernelUpdater.shared.isCurrentKernelVersion(appState.kernelVersion, matching: latest)
    }
}
