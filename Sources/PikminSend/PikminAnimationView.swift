import AVFoundation
import AppKit
import ImageIO
import SwiftUI

struct PikminAnimationView: View {
    let resourceName: String
    let hasItem: Bool
    var size: CGFloat = 250
    var loop: Bool = true
    var onFinished: (() -> Void)? = nil

    var body: some View {
        ZStack {
            if let movURL = Bundle.main.url(forResource: resourceName, withExtension: "mov") {
                AlphaMovPlayerView(url: movURL)
                    .frame(width: size, height: size)
            } else if let apngURL = Bundle.main.url(forResource: resourceName, withExtension: "png") {
                APNGPlayerView(url: apngURL, loop: loop, onFinished: onFinished)
                    .frame(width: size, height: size)
            } else {
                EmptyView()
            }

            if hasItem && resourceName != "pikmin_carry" {
                BotWCookingDocView()
                    .offset(y: -48)
            }
        }
    }
}

/// 仿薩爾達曠野之息鍋裡食物跳動效果的文件圖示（使用 TimelineView 免 @State 巨集）
private struct BotWCookingDocView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let hop = abs(sin(t * 7.5))
            let tilt = sin(t * 5.2) * 15.0
            let squashX = 1.0 - hop * 0.08
            let squashY = 1.0 + hop * 0.10

            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white)
                    .frame(width: 26, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(red: 0.72, green: 0.54, blue: 0.32), lineWidth: 1.8)
                    )
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.orange.opacity(0.75)).frame(width: 14, height: 2.5)
                    RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.55)).frame(width: 14, height: 2)
                    RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.55)).frame(width: 10, height: 2)
                }
            }
            .shadow(color: .black.opacity(0.22), radius: 3, y: 2)
            .rotationEffect(.degrees(tilt))
            .scaleEffect(x: squashX, y: squashY)
            .offset(y: -hop * 14.0)
        }
    }
}

private struct APNGPlayerView: NSViewRepresentable {
    let url: URL
    let loop: Bool
    let onFinished: (() -> Void)?

    func makeNSView(context: Context) -> APNGContainerNSView {
        let view = APNGContainerNSView()
        view.onFinished = onFinished
        view.loadAPNGIfNeeded(from: url, loop: loop)
        return view
    }

    func updateNSView(_ nsView: APNGContainerNSView, context: Context) {
        nsView.onFinished = onFinished
        nsView.loadAPNGIfNeeded(from: url, loop: loop)
    }
}

@MainActor
private final class APNGContainerNSView: NSView {
    private var frames: [CGImage] = []
    private var frameIndex = 0
    private var timer: Timer?
    private var currentURL: URL?
    private var shouldLoop = true
    private let imageLayer = CALayer()
    var onFinished: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    func loadAPNGIfNeeded(from url: URL, loop: Bool) {
        shouldLoop = loop
        guard currentURL != url else { return }
        loadAPNG(from: url, loop: loop)
    }

    func loadAPNG(from url: URL, loop: Bool) {
        currentURL = url
        shouldLoop = loop
        timer?.invalidate()
        frames.removeAll()
        frameIndex = 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            let count = CGImageSourceGetCount(source)
            var loaded: [CGImage] = []
            loaded.reserveCapacity(count)
            for i in 0..<count {
                if let img = CGImageSourceCreateImageAtIndex(source, i, nil) {
                    loaded.append(img)
                }
            }
            DispatchQueue.main.async {
                guard let self, !loaded.isEmpty else { return }
                self.frames = loaded
                self.imageLayer.contents = loaded[0]
                self.startTimer()
            }
        }
    }

    private func startTimer() {
        let newTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.frames.isEmpty else { return }
                let nextIndex = self.frameIndex + 1
                if nextIndex >= self.frames.count {
                    if self.shouldLoop {
                        self.frameIndex = 0
                    } else {
                        self.timer?.invalidate()
                        self.timer = nil
                        self.onFinished?()
                        return
                    }
                } else {
                    self.frameIndex = nextIndex
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.imageLayer.contents = self.frames[self.frameIndex]
                CATransaction.commit()
            }
        }
        // 使用 .common 模式，打開右鍵選單或 Popover 時動畫依然不會暫停！
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    deinit {
        timer?.invalidate()
    }
}

private struct AlphaMovPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AlphaMovContainerNSView {
        let view = AlphaMovContainerNSView()
        view.play(url: url)
        return view
    }

    func updateNSView(_ nsView: AlphaMovContainerNSView, context: Context) {}
}

@MainActor
private final class AlphaMovContainerNSView: NSView {
    private let queuePlayer = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer: AVPlayerLayer

    override init(frame frameRect: NSRect) {
        self.playerLayer = AVPlayerLayer(player: queuePlayer)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.isOpaque = false
        layer?.addSublayer(playerLayer)
        queuePlayer.isMuted = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func play(url: URL) {
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        queuePlayer.play()
    }
}
