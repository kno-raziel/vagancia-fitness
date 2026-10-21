// Original geometric app icon: an open track and forward chevron on opaque teal.
// Diagnostic app only. Run from any directory: swift apple/scripts/generate-icon.swift
import AppKit

let size = 1024
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
context.setFillColor(CGColor(red: 0, green: 0.39, blue: 0.39, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.setStrokeColor(CGColor(gray: 1, alpha: 1))
context.setLineWidth(80)
context.setLineCap(.round)
context.setLineJoin(.round)
context.addArc(
    center: CGPoint(x: 470, y: 512), radius: 280, startAngle: .pi * 0.20, endAngle: .pi * 1.80, clockwise: false)
context.strokePath()
context.move(to: CGPoint(x: 690, y: 630))
context.addLine(to: CGPoint(x: 810, y: 512))
context.addLine(to: CGPoint(x: 690, y: 394))
context.strokePath()
NSGraphicsContext.restoreGraphicsState()
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
let appleDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let destination = appleDirectory.appendingPathComponent(
    "Apps/VaganciaFitnessDebug/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
print(destination.path)
