import Cocoa
import SwiftUI

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
    private let appSettings = AppSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        DaemonLogger.shared.log("APP", "应用启动，版本: \(version)")
        DaemonLogger.shared.log("APP", "Bundle: \(Bundle.main.bundleURL.path)")

        ProxyManager.shared.delegate = self

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMihomoCrashed),
            name: .mihomoCrashed,
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
        DaemonLogger.shared.log("SUB", "收到保存通知: \(savedURL.prefix(40))...")
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

    @objc private func handleMihomoCrashed(_ notification: Notification) {
        mihomoService.recordCrash()

        guard !mihomoService.isInCrashLoop() else {
            DaemonLogger.shared.log("KERNEL", "❌ 崩溃次数过多，已停止自动重启")
            let alert = NSAlert()
            alert.messageText = "Mihomo 内核反复崩溃"
            alert.informativeText = "请检查订阅配置或重新启动应用。如果问题持续，可能需要更新 Mihomo 内核。"
            alert.alertStyle = .critical
            alert.runModal()
            return
        }

        Task {
            do {
                DaemonLogger.shared.log("KERNEL", "自动重启中...")
                try await mihomoService.start()
                async let _ = mihomoService.fetchKernelVersion()
                async let _ = ProxyManager.shared.refreshProxyList()
                _ = await ((), ())
                appState.syncFromServices(mihomo: mihomoService, proxy: ProxyManager.shared)
                syncUI()
                DaemonLogger.shared.log("KERNEL", "自动重启完成")
            } catch {
                DaemonLogger.shared.log("KERNEL", "❌ 自动重启失败: \(error.localizedDescription)")
                showError("Mihomo 内核崩溃后自动重启失败: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - MenuControllerDelegate

extension AppDelegate: MenuControllerDelegate {
    func menuWillOpen() {
        appState.isProxyEnabled = mihomoService.isSystemProxyEnabled()
        appState.isRunning = mihomoService.isRunning
        rebuildMenu()
        // 后台刷新代理列表，下次打开菜单时生效
        Task { await coordinator.refreshProxies() }
    }

    func selectProxy(name: String, in group: String) {
        // 菜单已关闭，无需重建
        Task { await coordinator.selectProxy(name: name, in: group) }
    }

    func toggleProxy() {
        coordinator.toggleProxy()
        syncUI()
    }

    func openSettings() {
        openSubscriptionSettingsWindow()
    }

    func quitApp() {
        coordinator.prepareForQuit()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - ProxyManagerDelegate

extension AppDelegate: ProxyManagerDelegate {
    func proxyManagerDidRefresh(_ manager: ProxyManager) {
        syncUI()
    }
}
