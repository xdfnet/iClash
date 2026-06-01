import SwiftUI

extension Notification.Name {
    static let openSubscriptionSettings = Notification.Name("openSubscriptionSettings")
    static let subscriptionSettingsDidSave = Notification.Name("subscriptionSettingsDidSave")
}

struct SubscriptionSettingsView: View {
    @State private var subscriptionURL: String = ""
    @State private var alertMessage: String = ""
    @State private var showAlert = false

    private let settings = AppSettings.shared
    var onDismiss: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                configSection
            }
            .padding(20)
        }
        .frame(width: 540, height: 280)
        .onAppear {
            subscriptionURL = settings.subscriptionURL
        }
        .alert("提示", isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("订阅设置")
                .font(.headline)
            Text("保存后会立即重载订阅并尝试启动服务；留空保存则只保留菜单栏，不启动内核。")
                .foregroundColor(.secondary)
        }
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("订阅地址")
                .font(.subheadline)
                .foregroundColor(.secondary)

            TextField("https://example.com/subscription", text: $subscriptionURL, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .lineLimit(3...6)

            HStack(spacing: 12) {
                Button("保存", action: saveSettings)
                    .buttonStyle(PrimaryButtonStyle())

                Button("清空", action: clearSettings)
                    .buttonStyle(.bordered)

                Spacer()
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
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

    private func clearSettings() {
        subscriptionURL = ""
        saveSettings()
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
