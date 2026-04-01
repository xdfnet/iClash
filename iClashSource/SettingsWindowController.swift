import Cocoa

/// 设置窗口控制器
@MainActor
final class SettingsWindowController: NSWindowController {
    weak var delegate: SettingsWindowDelegate?

    init() {
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

        super.init(window: window)

        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContent() {
        guard let window else { return }

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 60))
        contentView.wantsLayer = true
        window.contentView = contentView

        let textField = NSTextField(frame: NSRect(x: 20, y: 20, width: 400, height: 24))
        textField.stringValue = ConfigManager.shared.subscriptionURL
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
    }

    @objc private func saveSettings(_ sender: NSButton) {
        guard let contentView = sender.superview,
              let textField = contentView.subviews.first(where: { $0 is NSTextField }) as? NSTextField else {
            return
        }

        let newURL = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newURL.isEmpty else { return }

        delegate?.saveSettings(url: newURL)
        window?.close()
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

protocol SettingsWindowDelegate: AnyObject {
    func saveSettings(url: String)
}
