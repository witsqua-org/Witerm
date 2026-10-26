#!/usr/bin/env swift
// Run from the repository root: swift scripts/GenerateBrandAssets.swift
// Vector geometry is shared by the exported mark and all app-icon variants.
// Color tokens live in the asset catalog (with Increase Contrast variants);
// this script draws only the mark and icons.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("apps/apple/Sources/Assets.xcassets")
let brand = root.appendingPathComponent("design/brand")
let fm = FileManager.default

func writeJSON(_ value: [String: Any], to url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

/// The cursor runs through the machine identity hues (dark variants): the
/// interface is neutral and color belongs to the machines Witerm reaches.
let cursorSpectrum: [UInt32] = [0xFF6B8B, 0xFFC24B, 0x4FE3B0, 0x5CC8FF, 0xB58CFF]
let markInk: UInt32 = 0xECEEF2

func drawMark(in context: CGContext, rect: CGRect, monochrome: Bool = false) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.minY)
    context.scaleBy(x: rect.width, y: rect.height)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(color(markInk))
    context.setLineWidth(0.105)
    context.move(to: CGPoint(x: 0.12, y: 0.72))
    context.addLine(to: CGPoint(x: 0.30, y: 0.25))
    context.addLine(to: CGPoint(x: 0.50, y: 0.55))
    context.addLine(to: CGPoint(x: 0.70, y: 0.25))
    context.addLine(to: CGPoint(x: 0.88, y: 0.72))
    context.strokePath()
    context.setLineWidth(0.065)
    context.move(to: CGPoint(x: 0.72, y: 0.09))
    context.addLine(to: CGPoint(x: 0.90, y: 0.09))
    if monochrome {
        context.setStrokeColor(color(markInk))
        context.strokePath()
    } else {
        context.replacePathWithStrokedPath()
        context.clip()
        let spectrum = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cursorSpectrum.map(color) as CFArray, locations: nil)!
        context.drawLinearGradient(spectrum, start: CGPoint(x: 0.69, y: 0.09), end: CGPoint(x: 0.93, y: 0.09), options: [])
    }
    context.restoreGState()
}

func icon(size: Int, variant: String, mac: Bool) throws -> Data {
    let alpha: CGImageAlphaInfo = mac ? .premultipliedLast : .noneSkipLast
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue) else {
        throw NSError(domain: "Brand", code: 1)
    }
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let tile = mac ? bounds.insetBy(dx: 100, dy: 100) : bounds
    if mac {
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: CGColor(gray: 0, alpha: 0.22))
        context.setFillColor(color(0x0E0F12))
        context.addPath(CGPath(roundedRect: tile, cornerWidth: 184, cornerHeight: 184, transform: nil))
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }
    context.saveGState()
    if mac {
        context.addPath(CGPath(roundedRect: tile, cornerWidth: 184, cornerHeight: 184, transform: nil))
        context.clip()
    }
    // Graphite, matching the neutral interface.
    let top: UInt32 = variant == "tinted" ? 0x242424 : (variant == "dark" ? 0x1C1E22 : 0x2C2F35)
    let bottom: UInt32 = variant == "tinted" ? 0x080808 : 0x0B0C0E
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(bottom), color(top)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 850, y: 0), end: CGPoint(x: 100, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
    if mac {
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
        context.setLineWidth(2)
        context.addPath(CGPath(roundedRect: tile.insetBy(dx: 1, dy: 1), cornerWidth: 184, cornerHeight: 184, transform: nil))
        context.strokePath()
    }
    let glyph = mac ? CGRect(x: 236, y: 236, width: 552, height: 552) : CGRect(x: 170, y: 170, width: 684, height: 684)
    drawMark(in: context, rect: glyph, monochrome: variant == "tinted")
    guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Brand", code: 2)
    }
    return png
}

try fm.createDirectory(at: brand, withIntermediateDirectories: true)
try writeJSON(["info": ["author": "xcode", "version": 1]], to: assets.appendingPathComponent("Contents.json"))

let markDirectory = assets.appendingPathComponent("BrandMark.imageset")
try fm.createDirectory(at: markDirectory, withIntermediateDirectories: true)
let pdf = NSMutableData()
var box = CGRect(x: 0, y: 0, width: 256, height: 256)
let pdfContext = CGContext(consumer: CGDataConsumer(data: pdf)!, mediaBox: &box, nil)!
pdfContext.beginPDFPage(nil)
drawMark(in: pdfContext, rect: box)
pdfContext.endPDFPage()
pdfContext.closePDF()
try (pdf as Data).write(to: markDirectory.appendingPathComponent("BrandMark.pdf"))
try writeJSON(["images": [["filename": "BrandMark.pdf", "idiom": "universal"]], "info": ["author": "xcode", "version": 1], "properties": ["preserves-vector-representation": true]], to: markDirectory.appendingPathComponent("Contents.json"))

var iconEntries: [[String: Any]] = []
let iOSDirectory = assets.appendingPathComponent("AppIcon.appiconset")
try fm.createDirectory(at: iOSDirectory, withIntermediateDirectories: true)
for variant in ["light", "dark", "tinted"] {
    let file = "AppIcon-\(variant).png"
    try icon(size: 1024, variant: variant, mac: false).write(to: iOSDirectory.appendingPathComponent(file))
    var entry: [String: Any] = ["filename": file, "idiom": "universal", "platform": "ios", "size": "1024x1024"]
    if variant != "light" { entry["appearances"] = [["appearance": "luminosity", "value": variant]] }
    iconEntries.append(entry)
}
try writeJSON(["images": iconEntries, "info": ["author": "xcode", "version": 1]], to: iOSDirectory.appendingPathComponent("Contents.json"))

let macDirectory = assets.appendingPathComponent("MacAppIcon.appiconset")
try fm.createDirectory(at: macDirectory, withIntermediateDirectories: true)
var macEntries: [[String: Any]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let file = "icon-\(points)@\(scale)x.png"
        try icon(size: points * scale, variant: "light", mac: true).write(to: macDirectory.appendingPathComponent(file))
        macEntries.append(["filename": file, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
try writeJSON(["images": macEntries, "info": ["author": "xcode", "version": 1]], to: macDirectory.appendingPathComponent("Contents.json"))

let stops = cursorSpectrum.enumerated().map { index, hex in
    "    <stop offset=\"\(index * 100 / (cursorSpectrum.count - 1))%\" stop-color=\"#\(String(format: "%06X", hex))\"/>"
}.joined(separator: "\n")
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" fill="none">
  <title>Witerm — W terminal mark</title>
  <defs>
    <linearGradient id="cursor" x1="69" y1="0" x2="93" y2="0" gradientUnits="userSpaceOnUse">
\(stops)
    </linearGradient>
  </defs>
  <path d="M12 28 30 75 50 45 70 75 88 28" stroke="#\(String(format: "%06X", markInk))" stroke-width="10.5" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M72 91H90" stroke="url(#cursor)" stroke-width="6.5" stroke-linecap="round"/>
</svg>
"""
try svg.write(to: brand.appendingPathComponent("witerm-mark.svg"), atomically: true, encoding: .utf8)
try icon(size: 1024, variant: "light", mac: false).write(to: brand.appendingPathComponent("witerm-icon.png"))
print("Generated vector mark, iOS icon appearances and macOS icon sizes.")
