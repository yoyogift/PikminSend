import AppKit
import SwiftUI

@MainActor
final class TextMessageWindowController {
    static let shared = TextMessageWindowController()

    private var panel: NSPanel?

    private init() {}

    func show(senderName: String, text: String) {
        panel?.close()

        let viewModel = TextMessageViewModel(text: text)
        let view = TextMessageView(viewModel: viewModel)

        let hosting = NSHostingController(rootView: view)
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 245),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "來自 \(senderName) 的文字訊息"
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.isReleasedWhenClosed = false
        newPanel.minSize = NSSize(width: 300, height: 180)
        newPanel.contentViewController = hosting

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let x = visible.minX + 24
            let y = visible.minY + 24
            newPanel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            newPanel.center()
        }

        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = newPanel
    }
}

@MainActor
private final class TextMessageViewModel: ObservableObject {
    let text: String
    @Published var copied = false

    init(text: String) {
        self.text = text
    }

    func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copied = false
        }
    }
}

private struct TextMessageView: View {
    @ObservedObject var viewModel: TextMessageViewModel

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                Text(viewModel.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
            )

            HStack(spacing: 10) {
                Button {
                    viewModel.copyToPasteboard()
                } label: {
                    Label(
                        viewModel.copied ? "已複製" : "複製",
                        systemImage: viewModel.copied ? "checkmark.circle.fill" : "doc.on.doc"
                    )
                    .frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.copied ? .green : .accentColor)
                .controlSize(.regular)
            }
        }
        .padding(14)
        .frame(minWidth: 300, minHeight: 180)
    }
}
