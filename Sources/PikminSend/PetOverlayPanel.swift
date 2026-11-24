import AppKit
import SwiftUI

enum BasketPayload: Equatable {
    case empty
    case file(URL)
    case text(String, isClipboard: Bool)

    var summary: String {
        switch self {
        case .empty:
            return "籃子是空的（右鍵或拖曳檔案裝入）"
        case .file(let url):
            return "檔案：\(url.lastPathComponent)"
        case .text(let content, let isClipboard):
            let prefix = isClipboard ? "剪貼板" : "文字"
            let singleLine = content.replacingOccurrences(of: "\n", with: " ")
            let clipped = singleLine.count > 22 ? String(singleLine.prefix(22)) + "…" : singleLine
            return "\(prefix)：\(clipped)"
        }
    }
}

@MainActor
final class PetOverlayPanel: NSPanel {
    private let viewModel: PetOverlayViewModel
    private let discovery: DiscoveryManager

    init(discovery: DiscoveryManager, localPortProvider: @escaping () -> Int, onTriggerTestPeek: @escaping () -> Void) {
        self.discovery = discovery
        self.viewModel = PetOverlayViewModel(localPortProvider: localPortProvider)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        viewModel.onDismiss = { [weak self] in
            self?.orderOut(nil)
        }
        viewModel.onTriggerTestPeek = onTriggerTestPeek

        let hostingView = NSHostingView(rootView: PetOverlayView(viewModel: viewModel, discovery: discovery))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = hostingView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func toggle() {
        if isVisible {
            orderOut(nil)
        } else {
            showCenteredNearBottom()
        }
    }

    func showCenteredNearBottom() {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            let x = frame.minX + 14
            let y = frame.minY + 12
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        viewModel.resetForAppearance()
        Task {
            await discovery.refreshAll()
        }
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            animator().alphaValue = 1
        }
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

@MainActor
final class PetOverlayViewModel: ObservableObject {
    @Published var payload: BasketPayload = .empty
    @Published var showBusStopMenu = false
    @Published var showTextComposer = false
    @Published var draftText = ""
    @Published var isCarryingAway = false
    @Published var isSending = false
    @Published var statusNote = "雙擊 Shift 召喚・右鍵或拖曳裝籃・點路牌選對象"

    private let localPortProvider: () -> Int

    var onDismiss: (() -> Void)?
    var onTriggerTestPeek: (() -> Void)?

    init(localPortProvider: @escaping () -> Int) {
        self.localPortProvider = localPortProvider
    }

    func resetForAppearance() {
        isCarryingAway = false
        isSending = false
        showBusStopMenu = false
        showTextComposer = false
        statusNote = "雙擊 Shift 召喚・右鍵或拖曳裝籃・點路牌選對象"
    }

    func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "放進籃子"
        if panel.runModal() == .OK, let url = panel.url {
            payload = .file(url)
        }
    }

    func loadClipboard() {
        if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty {
            payload = .text(str, isClipboard: true)
        } else {
            statusNote = "剪貼板目前沒有文字內容"
        }
    }

    func confirmDraftText() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            payload = .text(trimmed, isClipboard: false)
        }
        draftText = ""
        showTextComposer = false
    }

    func sendToPeer(_ peer: LocalSendPeer) {
        guard payload != .empty else {
            showBusStopMenu = false
            statusNote = "籃子是空的！請先按右鍵或拖曳放入檔案"
            return
        }
        guard !isSending else { return }

        showBusStopMenu = false
        isSending = true
        let currentPayload = payload
        let myPort = localPortProvider()
        statusNote = "正在等待 \(peer.alias) 確認接收…"

        Task {
            do {
                try await LocalSendClient.shared.send(payload: currentPayload, to: peer, localPort: myPort)
                statusNote = "已送達 \(peer.alias)！"
                withAnimation(.easeIn(duration: 0.7)) {
                    isCarryingAway = true
                }
                try? await Task.sleep(nanoseconds: 780_000_000)
                payload = .empty
                isSending = false
                onDismiss?()
            } catch {
                isSending = false
                statusNote = error.localizedDescription
            }
        }
    }
}

struct PetOverlayView: View {
    @ObservedObject var viewModel: PetOverlayViewModel
    @ObservedObject var discovery: DiscoveryManager

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 6) {
                if viewModel.showTextComposer {
                    HStack(spacing: 6) {
                        TextField("輸入要傳送的文字…", text: $viewModel.draftText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit { viewModel.confirmDraftText() }
                        Button("放入") { viewModel.confirmDraftText() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                // 狀態氣泡
                Text(viewModel.isSending || viewModel.payload == .empty ? viewModel.statusNote : viewModel.payload.summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)

                HStack(alignment: .bottom, spacing: 6) {
                    // 真實 3D 算圖皮克敏動畫（支援直接拖曳檔案進籃子）
                    PikminAnimationView(
                        resourceName: (viewModel.payload != .empty && Bundle.main.url(forResource: "pikmin_carry", withExtension: "png") != nil) ? "pikmin_carry" : "pikmin_idle",
                        hasItem: viewModel.payload != .empty
                    )
                    .id(viewModel.payload == .empty ? "idle" : "carry")
                        .contentShape(Rectangle())
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            guard let provider = providers.first else { return false }
                            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                                if let data = item as? Data,
                                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                                    Task { @MainActor in
                                        viewModel.payload = .file(url)
                                    }
                                }
                            }
                            return true
                        }
                        .contextMenu {
                            Button("選擇檔案放入籃子…") { viewModel.pickFile() }
                            Button("貼上剪貼板文字") { viewModel.loadClipboard() }
                            Button("輸入文字訊息…") { viewModel.showTextComposer.toggle() }
                            Divider()
                            Button("清空籃子") { viewModel.payload = .empty }
                            Button("測試左下角探頭接收") { viewModel.onTriggerTestPeek?() }
                            Button("先回上方休息 (Esc)") { viewModel.onDismiss?() }
                        }

                    // 巴士路牌
                    Button {
                        viewModel.showBusStopMenu.toggle()
                    } label: {
                        BusStopSignView()
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 68)
                    .popover(isPresented: $viewModel.showBusStopMenu, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("選擇傳送對象")
                                    .font(.headline)
                                Spacer()
                                Button {
                                    Task { await discovery.refreshAll() }
                                } label: {
                                    Image(systemName: discovery.isScanning ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.clockwise")
                                }
                                .buttonStyle(.plain)
                                .help("重新掃描區網與 Tailscale 節點")
                            }

                            if discovery.peers.isEmpty {
                                Text(discovery.isScanning ? "正在掃描區網與 Tailscale…" : "目前找不到其他 LocalSend 設備")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 220, alignment: .leading)
                                    .padding(.vertical, 6)
                            } else {
                                ForEach(discovery.peers) { peer in
                                    Button {
                                        viewModel.sendToPeer(peer)
                                    } label: {
                                        HStack {
                                            Image(systemName: peer.isTailscale ? "globe" : "wifi")
                                                .foregroundStyle(peer.isTailscale ? .blue : .green)
                                            VStack(alignment: .leading) {
                                                Text(peer.alias)
                                                    .font(.system(size: 13, weight: .semibold))
                                                Text("\(peer.isTailscale ? "Tailscale" : "區網 LAN") · \(peer.ip):\(peer.port)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }
                                        .frame(width: 230)
                                        .padding(.vertical, 4)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(12)
                    }
                }
                .offset(x: viewModel.isCarryingAway ? -280 : 0)
                .opacity(viewModel.isCarryingAway ? 0 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
    }
}

private struct BusStopSignView: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.96, green: 0.78, blue: 0.24))
                    .frame(width: 44, height: 44)
                    .overlay(Circle().stroke(.white, lineWidth: 2.5))
                Image(systemName: "bus.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.black.opacity(0.8))
            }
            Rectangle()
                .fill(Color.gray.opacity(0.85))
                .frame(width: 5, height: 42)
            Capsule()
                .fill(Color.gray.opacity(0.9))
                .frame(width: 26, height: 6)
        }
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }
}
