import AppKit
import SwiftUI

@MainActor
final class ReceiverPeekPanel: NSPanel {
    private let viewModel = ReceiverPeekViewModel()
    private var activeSessionId: String?
    private var decisionHandler: (@Sendable (Bool) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        viewModel.onAccept = { [weak self] in
            guard let self else { return }
            if let handler = self.decisionHandler {
                self.decisionHandler = nil
                handler(true)
            } else {
                if Bundle.main.url(forResource: "pikmin_peek_wave", withExtension: "png") == nil {
                    self.viewModel.statusLine = "已收下檔案！(測試)"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                        self?.dismissAnimated()
                    }
                }
            }
        }

        viewModel.onWaveFinished = { [weak self] in
            self?.dismissAnimated()
        }

        viewModel.onDecline = { [weak self] in
            guard let self else { return }
            let handler = self.decisionHandler
            self.decisionHandler = nil
            handler?(false)
            self.dismissAnimated()
        }

        let hostingView = NSHostingView(rootView: ReceiverPeekView(viewModel: viewModel))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = hostingView
    }

    func showOffer(_ offer: IncomingTransferOffer, decision: @escaping @Sendable (Bool) -> Void) {
        activeSessionId = offer.sessionId
        decisionHandler = decision
        viewModel.senderName = offer.senderName
        viewModel.itemSummary = offer.itemSummary
        viewModel.statusLine = "點我確認接收"
        viewModel.isAccepted = false
        presentFromBottomLeft()
    }

    func showPeek(senderName: String, itemSummary: String) {
        activeSessionId = nil
        decisionHandler = nil
        viewModel.senderName = senderName
        viewModel.itemSummary = itemSummary
        viewModel.statusLine = "點我確認接收"
        viewModel.isAccepted = false
        presentFromBottomLeft()
    }

    func markCompleted(savedURL: URL?, receivedText: String?) {
        if let receivedText {
            viewModel.statusLine = "已開啟文字內容！"
            TextMessageWindowController.shared.show(senderName: viewModel.senderName, text: receivedText)
        } else if let savedURL {
            viewModel.statusLine = "已存入下載：\(savedURL.lastPathComponent)"
        } else {
            viewModel.statusLine = "接收完成！"
        }

        if Bundle.main.url(forResource: "pikmin_peek_wave", withExtension: "png") == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                self?.dismissAnimated()
            }
        }
    }

    func cancelIfMatching(sessionId: String) {
        guard activeSessionId == sessionId else { return }
        decisionHandler = nil
        dismissAnimated()
    }

    private func presentFromBottomLeft() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame

        // 直接貼齊螢幕最左邊界
        setFrameOrigin(NSPoint(x: visible.minX, y: visible.minY + 12))
        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = 1
        }
    }

    private func dismissAnimated() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.orderOut(nil)
            }
        }
    }
}

@MainActor
final class ReceiverPeekViewModel: ObservableObject {
    @Published var senderName = "Windows-PC"
    @Published var itemSummary = "project_notes.pdf (2.4 MB)"
    @Published var statusLine = "點我確認接收"
    @Published var isAccepted = false

    var onAccept: (() -> Void)?
    var onDecline: (() -> Void)?
    var onWaveFinished: (() -> Void)?

    func acceptTransfer() {
        guard !isAccepted else { return }
        isAccepted = true
        statusLine = "已收下！"
        onAccept?()
    }

    func declineTransfer() {
        onDecline?()
    }
}

struct ReceiverPeekView: View {
    @ObservedObject var viewModel: ReceiverPeekViewModel

    private var hasPeekIdle: Bool {
        Bundle.main.url(forResource: "pikmin_peek_idle", withExtension: "png") != nil
    }

    private var hasPeekWave: Bool {
        Bundle.main.url(forResource: "pikmin_peek_wave", withExtension: "png") != nil
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: -112) {
            if hasPeekIdle {
                let animName = (viewModel.isAccepted && hasPeekWave) ? "pikmin_peek_wave" : "pikmin_peek_idle"
                let shouldLoop = !(viewModel.isAccepted && hasPeekWave)
                PikminAnimationView(
                    resourceName: animName,
                    hasItem: false,
                    size: 175,
                    loop: shouldLoop,
                    onFinished: {
                        if viewModel.isAccepted && hasPeekWave {
                            viewModel.onWaveFinished?()
                        }
                    }
                )
                .id(animName)
                .offset(x: -44)
            } else {
                VStack(spacing: -2) {
                    Circle().fill(Color.white).frame(width: 10, height: 10)
                    Rectangle().fill(Color.red).frame(width: 2, height: 8)
                    Circle()
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                        .overlay(
                            HStack(spacing: 5) {
                                Circle().fill(.white).frame(width: 6, height: 6)
                                Circle().fill(.white).frame(width: 6, height: 6)
                            }
                        )
                    Capsule()
                        .fill(Color.red)
                        .frame(width: 18, height: 24)
                }
                .rotationEffect(.degrees(14))
                .padding(.leading, 12)
                .padding(.bottom, 12)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(viewModel.isAccepted ? "皮克敏收下囉！" : "\(viewModel.senderName) 傳來")
                        .font(.system(size: 11.5, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    if !viewModel.isAccepted {
                        Button {
                            viewModel.declineTransfer()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(viewModel.itemSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(viewModel.statusLine)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(viewModel.isAccepted ? .green : .blue)
                    .lineLimit(1)
            }
            .frame(width: 162, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.acceptTransfer()
        }
    }
}
