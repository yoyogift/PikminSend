import AVFoundation
import AppKit
import CoreVideo
import Foundation

guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: swift pngs_to_hevc_alpha.swift <input_dir> <output_mov>\n", stderr)
    exit(1)
}

let inputDir = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

let fm = FileManager.default
let files = try fm.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension.lowercased() == "png" && $0.lastPathComponent.hasPrefix("frame_") }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !files.isEmpty else {
    fputs("No frame_*.png files found in \(inputDir.path)\n", stderr)
    exit(1)
}

guard let firstImg = NSImage(contentsOf: files[0]),
      let firstCG = firstImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Failed to read first frame\n", stderr)
    exit(1)
}

let width = firstCG.width
let height = firstCG.height

try? fm.removeItem(at: outputURL)
try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
let videoSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.proRes4444,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height
]

let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
input.expectsMediaDataInRealTime = false

let sourcePixelBufferAttributes: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height
]

let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: sourcePixelBufferAttributes
)

writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let fps: Int32 = 30
let colorSpace = CGColorSpaceCreateDeviceRGB()

for (index, fileURL) in files.enumerated() {
    while !input.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.005)
    }
    guard let img = NSImage(contentsOf: fileURL),
          let cgImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        continue
    }

    var pixelBuffer: CVPixelBuffer?
    guard let pool = adaptor.pixelBufferPool else { break }
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
    guard let buffer = pixelBuffer else { continue }

    CVPixelBufferLockBaseAddress(buffer, [])
    if let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    ) {
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    let pts = CMTime(value: CMTimeValue(index), timescale: fps)
    adaptor.append(buffer, withPresentationTime: pts)
}

input.markAsFinished()
let semaphore = DispatchSemaphore(value: 0)
writer.finishWriting {
    semaphore.signal()
}
semaphore.wait()

if writer.status == .completed {
    print("Created HEVC with Alpha: \(outputURL.path) (\(files.count) frames, \(width)x\(height))")
} else {
    fputs("Writer failed: \(writer.error?.localizedDescription ?? "unknown")\n", stderr)
    exit(1)
}
