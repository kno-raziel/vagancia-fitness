// Rasterize the supplied v8 vector for Apple's 1024 px app icon slot.
// Source paths and weave masks remain unchanged. Run from any directory.
import AppKit

let appleDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = appleDirectory.appendingPathComponent(
    "Apps/VaganciaFitness/Resources/Assets.xcassets/FitnessMark.imageset/FitnessMark.svg")
guard let symbol = NSImage(contentsOf: source) else { fatalError("Cannot load v8 SVG") }
let size = 1024
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 8 / 255.0, green: 8 / 255.0, blue: 8 / 255.0, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
symbol.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
let destination = appleDirectory.appendingPathComponent(
    "Apps/VaganciaFitness/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
print("Generated v8 icon: 1024×1024, opaque Black Paper background.")
