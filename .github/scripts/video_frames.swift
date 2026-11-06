// Saves frames of a simulator screen recording as PNGs, cropped to the top of the
// screen (the status bar and the Dynamic Island), for the Screenshots workflow:
//
//     swiftc -swift-version 5 -o video_frames video_frames.swift
//     video_frames <video> <output-folder> [seconds-between-frames] [height-in-pixels]
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: video_frames <video> <output-folder> [seconds-between-frames] [height-in-pixels]")
    exit(2)
}
let video = URL(fileURLWithPath: arguments[1])
let folder = URL(fileURLWithPath: arguments[2], isDirectory: true)
let step = arguments.count > 3 ? Double(arguments[3]) ?? 0.5 : 0.5
let height = arguments.count > 4 ? Int(arguments[4]) ?? 700 : 700

let asset = AVURLAsset(url: video)
let generator = AVAssetImageGenerator(asset: asset)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
let duration = CMTimeGetSeconds(asset.duration)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

var index = 0
var time = 0.0
while time < duration {
    let at = CMTime(seconds: time, preferredTimescale: 600)
    if let image = try? generator.copyCGImage(at: at, actualTime: nil) {
        let top = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: min(height, image.height))) ?? image
        let url = folder.appendingPathComponent(String(format: "frame-%03d.png", index))
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, top, nil)
            CGImageDestinationFinalize(destination)
        }
    }
    index += 1
    time += step
}
print("\(index) frames from \(String(format: "%.1f", duration)) s")
