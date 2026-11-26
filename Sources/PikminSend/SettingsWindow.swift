import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var viewModel: SettingsViewModel?

    private init() {}

    func show(discovery: DiscoveryManager) {
        if let existing = window {
            viewModel?.refresh()
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vm = SettingsViewModel(discovery: discovery)
        self.viewModel = vm
        let view = SettingsView(viewModel: vm)
        let hosting = NSHostingController(rootView: view)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "PikminSend 設定與教學"
        newWindow.isReleasedWhenClosed = false
        newWindow.contentViewController = hosting
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = newWindow
    }
}

@MainActor
private final class SettingsViewModel: ObservableObject {
    @Published var customAlias: String = LocalIdentity.customAlias
    @Published var savedToast = false
    @Published var hasAccessibility = ShiftDoubleTapMonitor.hasAccessibilityPermission

    private let discovery: DiscoveryManager
    private var activeObserver: NSObjectProtocol?

    init(discovery: DiscoveryManager) {
        self.discovery = discovery
        self.activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recheckAccessibility()
            }
        }
    }

    deinit {
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

    func refresh() {
        hasAccessibility = ShiftDoubleTapMonitor.hasAccessibilityPermission
        customAlias = LocalIdentity.customAlias
    }

    func applyAlias() {
        LocalIdentity.customAlias = customAlias
        customAlias = LocalIdentity.customAlias
        discovery.sendMulticastAnnouncement()
        savedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.savedToast = false
        }
    }

    func resetAlias() {
        customAlias = ""
        LocalIdentity.customAlias = ""
        discovery.sendMulticastAnnouncement()
        savedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.savedToast = false
        }
    }

    func requestAccessibility() {
        ShiftDoubleTapMonitor.promptAccessibilityPermission()
    }

    func recheckAccessibility() {
        hasAccessibility = ShiftDoubleTapMonitor.hasAccessibilityPermission
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("對外顯示名稱 (Sender)")
                    .font(.headline)
                HStack(spacing: 8) {
                    TextField(LocalIdentity.defaultAlias, text: $viewModel.customAlias)
                        .textFieldStyle(.roundedBorder)
                    Button("套用") {
                        viewModel.applyAlias()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("重設") {
                        viewModel.resetAlias()
                    }
                    .buttonStyle(.bordered)
                }
                Text(viewModel.savedToast ? "已更新名稱：\(LocalIdentity.alias)" : "目前對外顯示為：\(LocalIdentity.alias)")
                    .font(.caption)
                    .foregroundStyle(viewModel.savedToast ? .green : .secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("快捷鍵權限（雙擊 Shift 召喚）")
                    .font(.headline)
                HStack(spacing: 10) {
                    Image(systemName: viewModel.hasAccessibility ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(viewModel.hasAccessibility ? .green : .orange)
                    Text(viewModel.hasAccessibility ? "輔助使用權限：已授權" : "輔助使用權限：尚未授權（雙擊 Shift 需要此權限）")
                        .font(.subheadline)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button("前往系統設定授權…") {
                        viewModel.requestAccessibility()
                    }
                    .buttonStyle(.bordered)

                    Button("重新檢查") {
                        viewModel.recheckAccessibility()
                    }
                    .buttonStyle(.borderless)
                }
                if !viewModel.hasAccessibility {
                    Text("若雙擊 Shift 已可使用但此處仍顯示未授權，代表重新編譯後簽章已更新；請在系統設定移除舊的 PikminSend 後再重新加入即可。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("使用教學")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    TutorialRow(icon: "shift", text: "連按兩下 Shift 鍵（或點選單列葉子圖示）召喚皮克敏")
                    TutorialRow(icon: "tray.and.arrow.down", text: "將檔案拖曳到皮克敏／野餐籃，或按右鍵選擇檔案、剪貼板或輸入文字")
                    TutorialRow(icon: "signpost.right", text: "點擊右側黃色「巴士站牌」選擇區網或 Tailscale 對象送出")
                    TutorialRow(icon: "sparkles", text: "收到傳送時皮克敏會從螢幕左下角探頭，點擊即可確認接收")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 430, height: 410)
    }
}

private struct TutorialRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
