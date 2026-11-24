import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: swift pngs_to_apng.swift <input_dir> <output_apng>\n", stderr)
    exit(1)
}

let inputDir = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

let fm = FileManager.default
let files = try fm.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension.lowercased() == "png" && $0.lastPathComponent.hasPrefix("frame_") }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !files.isEmpty else {
    fputs("No frame_*.png files found\n", stderr)
    exit(1)
}

try? fm.removeItem(at: outputURL)
try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

guard let dest = CGImageDestinationCreateWithURL(
    outputURL as CFURL,
    UTType.png.identifier as CFString,
    files.count,
    nil
) else {
    fputs("Failed to create CGImageDestination\n", stderr)
    exit(1)
}

let fileProperties: [String: Any] = [
    kCGImagePropertyPNGDictionary as String: [
        kCGImagePropertyAPNGLoopCount as String: 0
    ]
]
CGImageDestinationSetProperties(dest, fileProperties as CFDictionary)

let frameProperties: [String: Any] = [
    kCGImagePropertyPNGDictionary as String: [
        kCGImagePropertyAPNGDelayTime as String: 1.0 / 30.0
    ]
]

let targetSize = 512
let colorSpace = CGColorSpaceCreateDeviceRGB()

for fileURL in files {
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
        ctx.clear(CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        if let scaled = ctx.makeImage() {
            CGImageDestinationAddImage(dest, scaled, frameProperties as CFDictionary)
        }
    }
}

if CGImageDestinationFinalize(dest) {
    print("Created APNG: \(outputURL.path) (\(files.count) frames, \(targetSize)x\(targetSize))")
} else {
    fputs("Failed to finalize APNG\n", stderr)
    exit(1)
}
