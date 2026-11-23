import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let pixels = Data(repeating: 128, count: 16 * 16 * 4)
let image = CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32,
  bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
  provider: CGDataProvider(data: pixels as CFData)!, decode: nil,
  shouldInterpolate: false, intent: .defaultIntent)!
for (name, type) in [("capture.heic", UTType.heic), ("capture.tiff", UTType.tiff)] {
  let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL,
    type.identifier as CFString, 1, nil)!
  let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2022:02:28 19:31:40",
    kCGImagePropertyExifOffsetTimeOriginal: "+08:00", kCGImagePropertyExifSubsecTimeOriginal: "120"]
  CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
  guard CGImageDestinationFinalize(destination) else { fatalError("Encoding failed: \(name)") }
}
