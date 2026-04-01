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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private let mihomoService = MihomoService.shared
    private let configManager = ConfigManager.shared
    private let logger = Logger(subsystem: "com.iclash.macos", category: "AppDelegate")

    // 缓存的代理数据
    private var cachedProxyGroups: [(name: String, proxies: [String])] = []
    private var isLoadingProxies = false
    // 当前选中的代理
    private var currentSelections: [String: String] = [:]
    // 缓存过期时间（秒）
    private var lastRefreshTime: Date?
    private let cacheValidDuration: TimeInterval = 2.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? configManager.ensureBaseConfigurationExists()
        setupStatusBar()

        // config.yaml 存在则启动服务
        if configManager.runtimeConfigFileExists {
            startProxyOnLaunch()
        }
    }

    private func startProxyOnLaunch() {
        Task { [weak self] in
            guard let self else { return }

            do {
                try await self.mihomoService.start()
                await self.refreshProxyList()

                await MainActor.run {
                    self.refreshProxySubmenu()
                }
            } catch {
                await MainActor.run {
                    self.showError("启动代理失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func refreshProxyList() async {
        // 订阅地址为空时，不加载代理
        if configManager.subscriptionURL.isEmpty {
            cachedProxyGroups = []
            currentSelections = [:]
            await MainActor.run {
                self.refreshProxySubmenu()
            }
            return
        }

        // 如果已经在加载，使用已有缓存
        if isLoadingProxies {
            await MainActor.run {
                self.refreshProxySubmenu()
            }
            return
        }

        // 缓存有效时直接使用缓存
        if let lastTime = lastRefreshTime,
           Date().timeIntervalSince(lastTime) < cacheValidDuration,
           !cachedProxyGroups.isEmpty {
            await MainActor.run {
                self.refreshProxySubmenu()
            }
            return
        }

        isLoadingProxies = true

        do {
            // 如果 mihomo 还没启动，先启动
            if !mihomoService.isRunning {
                try await mihomoService.start()
            }

            let proxies = try await mihomoService.fetchProxies()

            // 1. 从 config 获取正确的 group 顺序和代理列表
            let configGroups = configManager.parseProxyGroupsOrder()
            var groups: [(name: String, proxies: [String])] = []
            var selections: [String: String] = [:]

            for (groupName, configProxies) in configGroups {
                // 在 API 响应中确认 group 存在
                if let info = proxies[groupName] {
                    // 使用 config 中定义的 proxies 列表
                    groups.append((name: groupName, proxies: configProxies))
                    if let now = info.now {
                        selections[groupName] = now
                    }
                }
            }

            cachedProxyGroups = groups
            currentSelections = selections
            lastRefreshTime = Date()
        } catch {
            print("[iClash] 加载代理列表失败: \(error)")
        }

        isLoadingProxies = false
        // 刷新菜单
        await MainActor.run {
            self.refreshProxySubmenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mihomoService.stop()
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusBarItem?.button {
            updateStatusIcon()
            button.action = #selector(statusBarButtonClicked)
            button.target = self
            button.imagePosition = .imageOnly
        }

        setupMenu()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateStatusIcon),
            name: NSNotification.Name("MihomoStatusChanged"),
            object: nil
        )
    }

    @objc private func updateStatusIcon(_ notification: Notification? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let button = self?.statusBarItem?.button else { return }
            let symbolName = self?.mihomoService.isRunning == true ? "circle.fill" : "circle"
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "iClash") {
                image.isTemplate = true
                button.image = image
            }
            button.title = ""
        }
    }

    // MARK: - Menu

    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self

        // 切换节点
        let switchItem = NSMenuItem(title: "切换节点", action: nil, keyEquivalent: "")
        switchItem.submenu = buildProxySubmenu()
        if let img = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Switch") {
            img.isTemplate = true
            switchItem.image = img
        }
        menu.addItem(switchItem)

        menu.addItem(NSMenuItem.separator())

        // 设置
        let settingsItem = NSMenuItem(title: "设置", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        if let img = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings") {
            img.isTemplate = true
            settingsItem.image = img
        }
        menu.addItem(settingsItem)

        // 退出
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        if let img = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit") {
            img.isTemplate = true
            quitItem.image = img
        }
        menu.addItem(quitItem)

        statusMenu = menu
        statusBarItem?.menu = menu
    }

    @objc private func openSettings() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 60),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "订阅设置"
        window.center()
        window.isFloatingPanel = true
        window.level = .floating
        window.backgroundColor = NSColor.windowBackgroundColor

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 60))
        contentView.wantsLayer = true
        window.contentView = contentView

        let textField = NSTextField(frame: NSRect(x: 20, y: 20, width: 400, height: 24))
        textField.stringValue = configManager.subscriptionURL
        textField.placeholderString = "输入订阅地址"
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.bezelStyle = .roundedBezel
        textField.tag = 101
        contentView.addSubview(textField)

        let saveBtn = NSButton(frame: NSRect(x: 430, y: 20, width: 50, height: 24))
        saveBtn.title = "保存"
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.target = self
        saveBtn.action = #selector(saveSettings(_:))
        saveBtn.tag = 100
        contentView.addSubview(saveBtn)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func saveSettings(_ sender: NSButton) {
        // sender 的 superview 是 contentView
        guard let contentView = sender.superview else {
            logger.error("contentView not found")
            return
        }

        // 从 contentView 找 textField
        guard let textField = contentView.subviews.first(where: { $0 is NSTextField }) as? NSTextField else {
            logger.error("textField in contentView not found")
            return
        }

        let newURL = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newURL.isEmpty else { return }

        // 先下载订阅，验证 URL 有效性
        Task {
            do {
                // 1. 下载订阅并保存到 config.yaml
                _ = try await self.configManager.downloadAndValidateConfig(url: newURL)

                // 2. 保存 URL
                await MainActor.run {
                    self.configManager.subscriptionURL = newURL
                }

                // 3. 停止旧服务
                self.mihomoService.stop()

                // 4. 启动新服务
                try await self.mihomoService.start()

                // 5. 关闭窗口
                await MainActor.run {
                    sender.window?.close()
                }

                // 6. 刷新菜单
                await self.refreshProxyList()
                self.refreshProxySubmenu()
            } catch {
                // 下载/启动失败：提示错误，不保存 URL
                await MainActor.run {
                    self.showError("\(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func statusBarButtonClicked() {
        // 每次点击都刷新代理列表
        Task { [weak self] in
            await self?.refreshProxyList()
        }
    }

    private func buildProxySubmenu() -> NSMenu {
        let submenu = NSMenu()

        guard mihomoService.isRunning else {
            submenu.addItem(NSMenuItem(title: "代理未启动", action: nil, keyEquivalent: ""))
            return submenu
        }

        // 如果没有缓存数据且没有在加载，先触发加载
        if cachedProxyGroups.isEmpty && !isLoadingProxies {
            submenu.addItem(NSMenuItem(title: "正在加载...", action: nil, keyEquivalent: ""))
            Task { [weak self] in
                await self?.refreshProxyList()
            }
            return submenu
        }

        // 如果正在加载，显示占位
        if isLoadingProxies && cachedProxyGroups.isEmpty {
            submenu.addItem(NSMenuItem(title: "正在加载...", action: nil, keyEquivalent: ""))
            return submenu
        }

        // 构建代理组子菜单
        for (groupName, proxyNames) in cachedProxyGroups {
            let groupItem = NSMenuItem(title: groupName, action: nil, keyEquivalent: "")
            let groupSubmenu = NSMenu()

            // 获取当前选中
            let selectedProxy = currentSelections[groupName]

            for proxyName in proxyNames {
                // 跳过 REJECT 和 REJECT-DROP，但不跳过 DIRECT（DIRECT 是有效代理选项）
                if proxyName == "REJECT" || proxyName == "REJECT-DROP" {
                    continue
                }

                let proxyItem = NSMenuItem(title: proxyName, action: #selector(selectProxy(_:)), keyEquivalent: "")
                proxyItem.target = self
                proxyItem.representedObject = ["name": proxyName, "group": groupName]

                // 显示选中状态
                if proxyName == selectedProxy {
                    proxyItem.state = .on
                }

                groupSubmenu.addItem(proxyItem)
            }

            if groupSubmenu.items.isEmpty {
                groupSubmenu.addItem(NSMenuItem(title: "无可用节点", action: nil, keyEquivalent: ""))
            }

            groupItem.submenu = groupSubmenu
            submenu.addItem(groupItem)
        }

        if submenu.items.isEmpty {
            submenu.addItem(NSMenuItem(title: "无可用代理组", action: nil, keyEquivalent: ""))
        }

        return submenu
    }

    private func refreshProxySubmenu() {
        guard let menu = statusMenu else { return }

        for item in menu.items {
            if item.title == "切换节点" {
                item.submenu = buildProxySubmenu()
                break
            }
        }
    }

    @objc private func selectProxy(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let name = info["name"],
              let group = info["group"] else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.mihomoService.selectProxy(name: name, in: group)
                // 切换成功后更新本地选中状态
                await MainActor.run {
                    self.currentSelections[group] = name
                    self.refreshProxySubmenu()
                }
            } catch {
                await MainActor.run {
                    self.showError("切换节点失败: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func quitApp() {
        print("[AppDelegate] quitApp called")
        mihomoService.stop()
        NSApplication.shared.terminate(nil)
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

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        Task { [weak self] in
            await self?.refreshProxyList()
            await MainActor.run {
                self?.refreshProxySubmenu()
            }
        }
    }
}
