import Cocoa

/// 菜单控制器 — 从 AppState 读状态构建菜单
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private weak var delegate: MenuControllerDelegate?
    private let coordinator: AppCoordinator
    private let appState: AppState

    init(delegate: MenuControllerDelegate, coordinator: AppCoordinator, appState: AppState) {
        self.delegate = delegate
        self.coordinator = coordinator
        self.appState = appState
        super.init()
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        // ── 启动/停止代理 ──
        let toggleTitle = appState.isProxyEnabled ? "停止代理" : "启动代理"
        let toggleImg = appState.isProxyEnabled ? "stop.circle" : "play.circle"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleProxy), keyEquivalent: "")
        toggleItem.target = self
        if let img = NSImage(systemSymbolName: toggleImg, accessibilityDescription: "Toggle") {
            img.isTemplate = true
            toggleItem.image = img
        }
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        // ── 切换节点 ──
        let switchItem = NSMenuItem(title: "切换节点", action: nil, keyEquivalent: "")
        switchItem.submenu = buildProxySubmenu()
        if let img = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Switch") {
            img.isTemplate = true
            switchItem.image = img
        }
        menu.addItem(switchItem)

        menu.addItem(NSMenuItem.separator())

        // ── 订阅设置 ──
        let settingsItem = NSMenuItem(title: "订阅设置", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        if let img = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings") {
            img.isTemplate = true
            settingsItem.image = img
        }
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // ── 版本信息 ──
        let infoItem = NSMenuItem(title: "软件版本", action: #selector(showKernelInfo), keyEquivalent: "")
        infoItem.target = self
        if let img = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Kernel") {
            img.isTemplate = true
            infoItem.image = img
        }
        menu.addItem(infoItem)

        menu.addItem(NSMenuItem.separator())

        // ── 退出 ──
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        if let img = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit") {
            img.isTemplate = true
            quitItem.image = img
        }
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - 代理子菜单

    private func buildProxySubmenu() -> NSMenu {
        let submenu = NSMenu()

        guard appState.isRunning else {
            submenu.addItem(NSMenuItem(title: "代理未启动", action: nil, keyEquivalent: ""))
            return submenu
        }

        if appState.proxyGroups.isEmpty && !appState.isLoadingProxies {
            submenu.addItem(NSMenuItem(title: "无可用代理", action: nil, keyEquivalent: ""))
            return submenu
        }

        if appState.isLoadingProxies && appState.proxyGroups.isEmpty {
            submenu.addItem(NSMenuItem(title: "正在加载...", action: nil, keyEquivalent: ""))
            return submenu
        }

        for (groupName, proxyNames) in appState.proxyGroups {
            let groupItem = NSMenuItem(title: groupName, action: nil, keyEquivalent: "")
            let groupSubmenu = NSMenu()
            let selectedProxy = appState.currentSelections[groupName]

            for proxyName in proxyNames {
                guard proxyName != "REJECT", proxyName != "REJECT-DROP" else { continue }

                let proxyItem = NSMenuItem(title: proxyName, action: #selector(selectProxy(_:)), keyEquivalent: "")
                proxyItem.target = self
                proxyItem.representedObject = ["name": proxyName, "group": groupName]

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

    // MARK: - 操作

    @objc private func selectProxy(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let name = info["name"],
              let group = info["group"] else { return }
        delegate?.selectProxy(name: name, in: group)
    }

    @objc private func toggleProxy() {
        delegate?.toggleProxy()
    }

    @objc private func openSettings() {
        delegate?.openSettings()
    }

    @objc private func quitApp() {
        delegate?.quitApp()
    }

    @objc private func showKernelInfo() {
        let currentVersion = appState.kernelVersion

        Task {
            let latestVersion = await (delegate?.fetchLatestVersion() ?? "获取失败")
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
            let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"

            let alert = NSAlert()
            alert.messageText = "版本信息"
            alert.informativeText = """
            软件版本: \(appVersion)
            构建版本: \(buildVersion)
            当前内核版本: \(currentVersion)
            最新内核版本: \(latestVersion)
            """
            alert.alertStyle = .informational

            let canUpdate = latestVersion != "获取失败"
                && !KernelUpdater.shared.isCurrentKernelVersion(currentVersion, matching: latestVersion)

            if canUpdate {
                alert.addButton(withTitle: "更新")
                alert.addButton(withTitle: "关闭")

                await MainActor.run {
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        delegate?.updateKernel()
                    }
                }
            } else {
                alert.addButton(withTitle: "关闭")
                alert.runModal()
            }
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        delegate?.menuWillOpen()
    }
}

// MARK: - 委托协议

@MainActor
protocol MenuControllerDelegate: AnyObject {
    func menuWillOpen()
    func selectProxy(name: String, in group: String)
    func toggleProxy()
    func openSettings()
    func updateKernel()
    func quitApp()
    func fetchLatestVersion() async -> String
    func canOfferUpdate() async -> Bool
}
