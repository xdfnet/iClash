import Cocoa

/// 状态栏控制器
@MainActor
final class StatusBarController: NSObject {
    private var statusBarItem: NSStatusItem?
    private var statusMenu: NSMenu?

    weak var delegate: StatusBarControllerDelegate?

    override init() {
        super.init()
        setupStatusBar()
    }

    private func setupStatusBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusBarItem?.button {
            updateStatusIcon(isRunning: false)
            button.action = #selector(statusBarButtonClicked)
            button.target = self
            button.imagePosition = .imageOnly
        }
    }

    @objc private func statusBarButtonClicked() {
        delegate?.statusBarButtonClicked()
    }

    func updateStatusIcon(isRunning: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let button = self?.statusBarItem?.button else { return }
            let symbolName = isRunning ? "circle.fill" : "circle"
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "iClash") {
                image.isTemplate = true
                button.image = image
            }
            button.title = ""
        }
    }

    func setMenu(_ menu: NSMenu) {
        statusMenu = menu
        statusBarItem?.menu = menu
    }

    func getMenu() -> NSMenu? {
        statusMenu
    }
}

protocol StatusBarControllerDelegate: AnyObject {
    func statusBarButtonClicked()
}
