import SwiftUI

extension Notification.Name {
    static let openSubscriptionSettings = Notification.Name("openSubscriptionSettings")
    static let subscriptionSettingsDidSave = Notification.Name("subscriptionSettingsDidSave")
}

// MARK: - 订阅设置表单

struct SubscriptionSettingsView: View {
    @State private var subscriptionURL: String = ""
    let currentURL: String
    let onSave: (String) -> Void
    let onDismiss: () -> Void

    init(currentURL: String, onSave: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        self._subscriptionURL = State(initialValue: currentURL)
        self.currentURL = currentURL
        self.onSave = onSave
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("订阅地址")
                .font(.headline)
            TextField("https://example.com/subscription", text: $subscriptionURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            HStack {
                Button("取消") { onDismiss() }
                    .keyboardShortcut(.escape)
                Button("保存") {
                    onSave(subscriptionURL)
                    onDismiss()
                }
                .keyboardShortcut(.return)
                .disabled(subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { subscriptionURL = currentURL }
    }
}

// MARK: - 窗口管理

@MainActor
final class SubscriptionSettingsWindow: NSWindowController {
    static let shared = SubscriptionSettingsWindow()

    private init() {
        let hosting = NSHostingController(rootView: EmptyView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "订阅设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(currentURL: String, onSave: @escaping (String) -> Void) {
        let dismissAction = { [weak self] in self?.dismiss(); () }
        let view = SubscriptionSettingsView(
            currentURL: currentURL,
            onSave: { url in onSave(url) },
            onDismiss: dismissAction
        )
        window?.contentViewController = NSHostingController(rootView: view)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.close()
    }
}
