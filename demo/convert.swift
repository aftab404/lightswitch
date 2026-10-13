// Trims a screen recording and exports an MP4 (Reddit, social posts, the site) and a GIF (README).
// Usage: swift demo/convert.swift <input.mov> <start seconds> <duration seconds> <output path without extension>
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 5, let start = Double(arguments[2]), let duration = Double(arguments[3]) else {
    print("usage: swift demo/convert.swift input.mov start duration output-base")
    exit(1)
}
let asset = AVURLAsset(url: URL(fileURLWithPath: arguments[1]))
let base = URL(fileURLWithPath: arguments[4])
let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                        duration: CMTime(seconds: duration, preferredTimescale: 600))

let mp4 = base.appendingPathExtension("mp4")
try? FileManager.default.removeItem(at: mp4)
guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
    fatalError("Could not create an export session")
}
session.timeRange = range
try await session.export(to: mp4, as: .mp4)
print("Wrote \(mp4.path)")

let gif = base.appendingPathExtension("gif")
let fps = 12.0
let frameCount = Int(duration * fps)
let generator = AVAssetImageGenerator(asset: asset)
generator.maximumSize = CGSize(width: 800, height: 800)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
guard let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
    fatalError("Could not create \(gif.path)")
}
CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                                       kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
for frame in 0..<frameCount {
    let (image, _) = try await generator.image(at: CMTime(seconds: start + Double(frame) / fps, preferredTimescale: 600))
    CGImageDestinationAddImage(destination, image, frameProperties)
}
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(gif.path)") }
print("Wrote \(gif.path)")
