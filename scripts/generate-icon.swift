#!/usr/bin/env swift
import AppKit
import CoreGraphics

// Renders a 1024x1024 Markzzy icon and writes PNGs for every required iconset size.
// Usage: swift scripts/generate-icon.swift <output-iconset-dir>

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

    // Palette — deep navy background, white "M.", blue accent dot.
    let navyTop = CGColor(red: 0.07, green: 0.13, blue: 0.27, alpha: 1)  // #121F45
    let navyBot = CGColor(red: 0.02, green: 0.05, blue: 0.12, alpha: 1)  // #060D1F
    let white   = CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1)
    let blue    = CGColor(red: 0.18, green: 0.56, blue: 1.00, alpha: 1)  // accent dot

    // Rounded-rect background with vertical navy gradient.
    let corner = size * 0.22
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    let bgGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [navyTop, navyBot] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: 0, y: size),
        end:   CGPoint(x: 0, y: 0),
        options: []
    )

    // Bold italic "M" — nudged left to compensate for the italic slant so the
    // optical center aligns with the card's center.
    let mFontSize = size * 0.62
    let font = NSFont.systemFont(ofSize: mFontSize, weight: .black)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: white) ?? .white,
        .obliqueness: 0.18,
        .paragraphStyle: paragraph,
    ]
    let letter = "M" as NSString
    let letterSize = letter.size(withAttributes: attrs)
    let letterOrigin = CGPoint(
        x: (size - letterSize.width) / 2 - size * 0.035,
        y: (size - letterSize.height) / 2 - size * 0.015
    )
    letter.draw(at: letterOrigin, withAttributes: attrs)
    _ = blue

    // Recording indicator — crisp red REC dot tucked just above the M's right arm.
    // Positioned to match the in-app LogoMark (center at ~84% / ~31% from top).
    let red  = CGColor(red: 1.00, green: 0.25, blue: 0.30, alpha: 1)
    let dotD = size * 0.085
    let dotCenterX = size * 0.84
    let dotCenterY = size * 0.69   // CG: y from bottom
    let dotRect = CGRect(
        x: dotCenterX - dotD / 2,
        y: dotCenterY - dotD / 2,
        width: dotD, height: dotD
    )
    ctx.setShadow(offset: .zero, blur: size * 0.018, color: red)
    ctx.setFillColor(red)
    ctx.fillEllipse(in: dotRect)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    return image
}

func writePNG(image: NSImage, to path: String, size: CGFloat) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

struct Variant { let name: String; let size: CGFloat }
let variants: [Variant] = [
    .init(name: "icon_16x16.png", size: 16),
    .init(name: "icon_16x16@2x.png", size: 32),
    .init(name: "icon_32x32.png", size: 32),
    .init(name: "icon_32x32@2x.png", size: 64),
    .init(name: "icon_128x128.png", size: 128),
    .init(name: "icon_128x128@2x.png", size: 256),
    .init(name: "icon_256x256.png", size: 256),
    .init(name: "icon_256x256@2x.png", size: 512),
    .init(name: "icon_512x512.png", size: 512),
    .init(name: "icon_512x512@2x.png", size: 1024),
]

let master = drawIcon(size: 1024)
for v in variants {
    let sized = drawIcon(size: v.size)
    writePNG(image: sized, to: "\(outDir)/\(v.name)", size: v.size)
    print("wrote \(v.name)")
}
_ = master
print("done")
