import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let shiftMonitor = ShiftDoubleTapMonitor()
    private let server = LocalSendServer()
    private let discovery = DiscoveryManager()

    private lazy var petOverlayPanel = PetOverlayPanel(
        discovery: discovery,
        localPortProvider: { [weak self] in self?.server.boundPort ?? 53317 },
        onTriggerTestPeek: { [weak self] in self?.triggerTestPeek() }
    )
    private lazy var receiverPeekPanel = ReceiverPeekPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupNetworking()
        setupStatusBar()
        setupFnMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        discovery.stop()
        server.stop()
    }

    private func setupNetworking() {
        server.onPeerSeen = { [weak self] info, ip in
            Task { @MainActor in
                self?.discovery.registerOrUpdatePeer(info: info, ip: ip)
            }
        }

        server.onIncomingOffer = { [weak self] offer, decision in
            Task { @MainActor in
                self?.receiverPeekPanel.showOffer(offer, decision: decision)
            }
        }

        server.onIncomingCancelled = { [weak self] sessionId in
            Task { @MainActor in
                self?.receiverPeekPanel.cancelIfMatching(sessionId: sessionId)
            }
        }

        server.onTransferCompleted = { [weak self] _, savedURL, receivedText in
            Task { @MainActor in
                self?.receiverPeekPanel.markCompleted(savedURL: savedURL, receivedText: receivedText)
            }
        }

        server.start()
        discovery.start(localPort: server.boundPort)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.discovery.updateLocalPort(self.server.boundPort)
        }
    }

    private func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "PikminSend")
            button.toolTip = "PikminSend（連按兩下 Shift 召喚）"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "召喚皮克敏 (連按兩下 Shift)", action: #selector(toggleOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重新掃描區網與 Tailscale", action: #selector(refreshPeers), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "測試左下角探頭接收", action: #selector(triggerTestPeek), keyEquivalent: ""))
        menu.addItem(.separator())

        let axTitle = ShiftDoubleTapMonitor.hasAccessibilityPermission
            ? "輔助使用權限：已授權"
            : "授權輔助使用權限 (雙擊 Shift 必備)…"
        menu.addItem(NSMenuItem(title: axTitle, action: #selector(requestAccessibility), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "結束 PikminSend", action: #selector(quitApp), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func setupFnMonitor() {
        shiftMonitor.onDoubleTap = { [weak self] in
            self?.petOverlayPanel.toggle()
        }
        shiftMonitor.start()

        if !ShiftDoubleTapMonitor.hasAccessibilityPermission {
            ShiftDoubleTapMonitor.promptAccessibilityPermission()
        }
    }

    @objc private func toggleOverlay() {
        petOverlayPanel.toggle()
    }

    @objc private func refreshPeers() {
        Task {
            await discovery.refreshAll()
        }
    }

    @objc private func triggerTestPeek() {
        receiverPeekPanel.showPeek(senderName: "Windows-PC (Tailscale)", itemSummary: "demo_photo.png · 3.2 MB")
    }

    @objc private func requestAccessibility() {
        ShiftDoubleTapMonitor.promptAccessibilityPermission()
        setupStatusBar()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
