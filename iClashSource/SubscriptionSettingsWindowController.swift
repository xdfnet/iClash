import Cocoa
import SwiftUI

@MainActor
final class SubscriptionSettingsWindowController: NSWindowController {
    static let shared = SubscriptionSettingsWindowController()

    private init() {
        let hostingController = NSHostingController(rootView: SubscriptionSettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "订阅设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 540, height: 240))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        let dismissAction = { [weak self] in
            self?.dismiss()
            return ()
        }
        window?.contentViewController = NSHostingController(rootView: SubscriptionSettingsView(onDismiss: dismissAction))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.close()
    }
}
