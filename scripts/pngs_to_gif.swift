import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: swift pngs_to_gif.swift <input_dir> <output_gif>\n", stderr)
    exit(1)
}

let inputDir = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

let fm = FileManager.default
let files = try fm.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension.lowercased() == "png" && $0.lastPathComponent.hasPrefix("frame_") }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !files.isEmpty else {
    fputs("No frame_*.png found in \(inputDir.path)\n", stderr)
    exit(1)
}

// 每 2 幀取 1 幀 (15fps) 讓 GIF 體積輕巧又流暢
let sampled = stride(from: 0, to: files.count, by: 2).map { files[$0] }

try? fm.removeItem(at: outputURL)
try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

guard let dest = CGImageDestinationCreateWithURL(
    outputURL as CFURL,
    UTType.gif.identifier as CFString,
    sampled.count,
    nil
) else {
    fputs("Failed to create GIF destination\n", stderr)
    exit(1)
}

let fileProps: [String: Any] = [
    kCGImagePropertyGIFDictionary as String: [
        kCGImagePropertyGIFLoopCount as String: 0
    ]
]
CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

let frameProps: [String: Any] = [
    kCGImagePropertyGIFDictionary as String: [
        kCGImagePropertyGIFDelayTime as String: 1.0 / 15.0
    ]
]

let targetSize = 360
let colorSpace = CGColorSpaceCreateDeviceRGB()

for fileURL in sampled {
    guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        continue
    }

    if let ctx = CGContext(
        data: nil,
        width: targetSize,
        height: targetSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) {
        ctx.interpolationQuality = .high
        // 墊上淺灰白底色，避免 GIF 1-bit 透明邊緣產生鋸齒白邊
        ctx.setFillColor(CGColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        if let rendered = ctx.makeImage() {
            CGImageDestinationAddImage(dest, rendered, frameProps as CFDictionary)
        }
    }
}

if CGImageDestinationFinalize(dest) {
    print("Created GIF: \(outputURL.path) (\(sampled.count) frames, \(targetSize)x\(targetSize))")
} else {
    fputs("Failed to finalize GIF\n", stderr)
    exit(1)
}
