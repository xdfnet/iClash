import Cocoa

/// 菜单控制器
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private weak var delegate: MenuControllerDelegate?

    init(delegate: MenuControllerDelegate) {
        self.delegate = delegate
        super.init()
    }

    func buildMenu() -> NSMenu {
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
        let settingsItem = NSMenuItem(title: "设置订阅", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        if let img = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings") {
            img.isTemplate = true
            settingsItem.image = img
        }
        menu.addItem(settingsItem)

        // 内核版本
        let selectorItem = NSMenuItem(title: "内核版本", action: #selector(showKernelInfo), keyEquivalent: "")
        selectorItem.target = self
        if let img = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Kernel") {
            img.isTemplate = true
            selectorItem.image = img
        }
        menu.addItem(selectorItem)

        menu.addItem(NSMenuItem.separator())

        // 退出
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        if let img = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit") {
            img.isTemplate = true
            quitItem.image = img
        }
        menu.addItem(quitItem)

        return menu
    }

    private func buildProxySubmenu() -> NSMenu {
        let submenu = NSMenu()
        let proxyManager = ProxyManager.shared
        let mihomoService = MihomoService.shared

        guard mihomoService.isRunning else {
            submenu.addItem(NSMenuItem(title: "代理未启动", action: nil, keyEquivalent: ""))
            return submenu
        }

        if proxyManager.proxyGroups.isEmpty && !proxyManager.isLoadingProxies {
            submenu.addItem(NSMenuItem(title: "正在加载...", action: nil, keyEquivalent: ""))
            Task {
                await proxyManager.refreshProxyList()
                delegate?.menuNeedsUpdate()
            }
            return submenu
        }

        if proxyManager.isLoadingProxies && proxyManager.proxyGroups.isEmpty {
            submenu.addItem(NSMenuItem(title: "正在加载...", action: nil, keyEquivalent: ""))
            return submenu
        }

        for (groupName, proxyNames) in proxyManager.proxyGroups {
            let groupItem = NSMenuItem(title: groupName, action: nil, keyEquivalent: "")
            let groupSubmenu = NSMenu()
            let selectedProxy = proxyManager.currentSelection(for: groupName)

            for proxyName in proxyNames {
                if proxyName == "REJECT" || proxyName == "REJECT-DROP" {
                    continue
                }

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

    @objc private func selectProxy(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let name = info["name"],
              let group = info["group"] else { return }

        delegate?.selectProxy(name: name, in: group)
    }

    @objc private func openSettings() {
        delegate?.openSettings()
    }

    @objc private func quitApp() {
        delegate?.quitApp()
    }

    @objc private func showKernelInfo() {
        Task {
            let currentVersion = MihomoService.shared.kernelVersion
            let latestVersion = await KernelUpdater.shared.fetchLatestVersion() ?? "获取失败"

            let alert = NSAlert()
            alert.messageText = "版本更新"
            alert.informativeText = "当前内核版本: \(currentVersion)\n最新内核版本: \(latestVersion)"
            alert.alertStyle = .informational

            // 版本不一样时显示更新和关闭，一样时只显示关闭
            if currentVersion != latestVersion {
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

protocol MenuControllerDelegate: AnyObject {
    func menuWillOpen()
    func menuNeedsUpdate()
    func selectProxy(name: String, in group: String)
    func openSettings()
    func updateKernel()
    func quitApp()
}
