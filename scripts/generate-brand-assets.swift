#!/usr/bin/env swift
// Packages the approved artwork without redrawing it. Run from the repository root.
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let catalog = root.appendingPathComponent("HeyNotch/Assets.xcassets", isDirectory: true)
let brand = root.appendingPathComponent("design/brand", isDirectory: true)
let manager = FileManager.default

func resize(_ source: URL, to destination: URL, width: Int, height: Int) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = ["--resampleHeightWidth", "\(height)", "\(width)", source.path, "--out", destination.path]
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
}

func writeContents(_ images: [[String: String]], at directory: URL, template: Bool = false) throws {
    var contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    if template { contents["properties"] = ["template-rendering-intent": "template"] }
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("Contents.json"), options: .atomic)
}

func imageSet(_ name: String, source: URL, width: Int, height: Int, template: Bool = false) throws {
    let directory = catalog.appendingPathComponent("\(name).imageset", isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for scale in 1...2 {
        let filename = "\(name)@\(scale)x.png"
        try resize(source, to: directory.appendingPathComponent(filename), width: width * scale, height: height * scale)
        images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x"])
    }
    try writeContents(images, at: directory, template: template)
}

let symbol = brand.appendingPathComponent("heynotch-symbol-v1.png")
let icon = brand.appendingPathComponent("heynotch-app-icon-v1.png")
guard manager.fileExists(atPath: symbol.path), manager.fileExists(atPath: icon.path) else {
    fatalError("Run from the repository root with the approved brand masters present.")
}

try imageSet("HeyNotchSymbol", source: symbol, width: 256, height: 256)
try imageSet("HeyNotchAppIcon", source: icon, width: 128, height: 128)

// Reframe only the transparent margins for a legible menu-bar template. The 11:7
// rectangle preserves the emblem's proportions at both 22×14 and 44×28 pixels.
let temporary = manager.temporaryDirectory.appendingPathComponent("heynotch-menu-\(UUID().uuidString).png")
defer { try? manager.removeItem(at: temporary) }
guard let source = CGImageSourceCreateWithURL(symbol as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let cropped = image.cropping(to: CGRect(x: 125, y: 310, width: 1001, height: 637)),
      let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("Cannot prepare the approved symbol for the menu bar.") }
CGImageDestinationAddImage(destination, cropped, nil)
guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
try imageSet("HeyNotchMenuBar", source: temporary, width: 22, height: 14, template: true)

let iconSet = catalog.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
let oldContents = try Data(contentsOf: iconSet.appendingPathComponent("Contents.json"))
let oldImages = (try JSONSerialization.jsonObject(with: oldContents) as? [String: Any])?["images"] as? [[String: String]] ?? []
var iconImages: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in 1...2 {
        let filename = "heynotch-\(size)x\(size)@\(scale)x.png"
        try resize(icon, to: iconSet.appendingPathComponent(filename), width: size * scale, height: size * scale)
        iconImages.append(["filename": filename, "idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x"])
    }
}
try writeContents(iconImages, at: iconSet)
let currentFiles = Set(iconImages.compactMap { $0["filename"] })
for filename in oldImages.compactMap({ $0["filename"] }) where !currentFiles.contains(filename) {
    guard filename == URL(fileURLWithPath: filename).lastPathComponent else { continue }
    try manager.removeItem(at: iconSet.appendingPathComponent(filename))
}

// These unused first-party aliases carried the previous app branding. Credits
// and third-party artwork (including theboringteam and GitHub) remain untouched.
for name in ["logo.imageset", "logo2.imageset"] {
    let directory = catalog.appendingPathComponent(name, isDirectory: true)
    if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
}
print("Packaged 10 macOS app-icon slots and 3 Retina brand image sets.")
