import SwiftUI

extension Notification.Name {
    static let openSubscriptionSettings = Notification.Name("openSubscriptionSettings")
    static let subscriptionSettingsDidSave = Notification.Name("subscriptionSettingsDidSave")
}

struct SubscriptionSettingsView: View {
    @State private var subscriptionURL: String = ""

    private let settings = AppSettings.shared
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            TextField("https://example.com/subscription", text: $subscriptionURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack {
                Button("保存", action: saveSettings)
                    .buttonStyle(PrimaryButtonStyle())
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 600)
        .onAppear {
            subscriptionURL = settings.subscriptionURL
        }
    }

    private func saveSettings() {
        let trimmedURL = subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.subscriptionURL = trimmedURL
        NotificationCenter.default.post(
            name: .subscriptionSettingsDidSave,
            object: nil,
            userInfo: ["subscriptionURL": trimmedURL]
        )

        onDismiss?()
    }

}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(8)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

// MARK: - 窗口管理

@MainActor
final class SubscriptionSettingsWindow: NSWindowController {
    static let shared = SubscriptionSettingsWindow()

    private init() {
        let hostingController = NSHostingController(rootView: SubscriptionSettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "订阅设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 600, height: 100))
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
