import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Mechanical packaging only: retain visible source pixels, aspect ratio, and colors.
// Usage: swift scripts/prepare-brand-assets.swift /path/to/approved/brand [dist]
guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
    fputs("Usage: swift scripts/prepare-brand-assets.swift <approved-master-directory> [output-directory]\n", stderr)
    exit(2)
}
let masterRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputRoot = URL(fileURLWithPath: CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "dist", isDirectory: true)
try FileManager.default.createDirectory(at: outputRoot.appendingPathComponent("assets"), withIntermediateDirectories: true)
func load(_ name: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(masterRoot.appendingPathComponent(name) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw NSError(domain: "Brand", code: 1) }
    return image
}
func trimmed(_ image: CGImage) throws -> CGImage {
    let width = image.width, height = image.height
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    return try rgba.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "Brand", code: 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = bytes.bindMemory(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY,
              let normalized = context.makeImage(),
              let crop = normalized.cropping(to: CGRect(x: minX, y: minY, width: maxX-minX+1, height: maxY-minY+1)) else {
            throw NSError(domain: "Brand", code: 3)
        }
        print("trimmed visible artwork: \(crop.width) × \(crop.height)")
        return crop
    }
}
func export(_ image: CGImage, to path: String, width: Int, height: Int, inset: CGFloat) throws {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw NSError(domain: "Brand", code: 4) }
    let scale = min((CGFloat(width) - inset * 2) / CGFloat(image.width), (CGFloat(height) - inset * 2) / CGFloat(image.height))
    let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: (CGFloat(width)-w)/2, y: (CGFloat(height)-h)/2, width: w, height: h))
    guard let result = context.makeImage(), let destination = CGImageDestinationCreateWithURL(outputRoot.appendingPathComponent(path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw NSError(domain: "Brand", code: 5) }
    CGImageDestinationAddImage(destination, result, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Brand", code: 6) }
    print("wrote \(path): \(width) × \(height)")
}
let wordmark = try trimmed(load("heynotch-wordmark-v1.png"))
let wordmarkHeight = Int(ceil(CGFloat(600) * CGFloat(wordmark.height) / CGFloat(wordmark.width))) + 4
try export(wordmark, to: "assets/heynotch-wordmark.png", width: 600, height: wordmarkHeight, inset: 2)
let symbol = try trimmed(load("heynotch-symbol-v1.png"))
try export(symbol, to: "assets/heynotch-symbol.png", width: 256, height: 256, inset: 16)
try export(symbol, to: "favicon-32.png", width: 32, height: 32, inset: 2)
try export(symbol, to: "favicon-192.png", width: 192, height: 192, inset: 12)
try export(symbol, to: "apple-touch-icon.png", width: 180, height: 180, inset: 18)
