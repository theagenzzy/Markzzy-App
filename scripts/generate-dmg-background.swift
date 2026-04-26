#!/usr/bin/env swift
import AppKit
import CoreGraphics

// Renders a 600x400 Markzzy DMG mount-window background. Two slots for icons
// (app at x=150, Applications shortcut at x=450), arrow + "Drag to install"
// hint between them. Mirrors the navy gradient + accent of the app icon.
//
// Usage: swift scripts/generate-dmg-background.swift <output.png>

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "./Resources/dmg-background.png"

let width: CGFloat = 600
let height: CGFloat = 400

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fputs("no graphics context\n", stderr)
    exit(1)
}

// Palette
let navyTop = CGColor(red: 0.07, green: 0.13, blue: 0.27, alpha: 1)  // #121F45
let navyBot = CGColor(red: 0.02, green: 0.05, blue: 0.12, alpha: 1)  // #060D1F
let blue    = CGColor(red: 0.18, green: 0.56, blue: 1.00, alpha: 1)
let white80 = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.80)
let white35 = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.35)

// Vertical navy gradient
let cs = CGColorSpaceCreateDeviceRGB()
let grad = CGGradient(colorsSpace: cs, colors: [navyTop, navyBot] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: height), end: .zero, options: [])

// Subtle aurora glow behind the arrow center
ctx.saveGState()
let centerX = width / 2
let centerY: CGFloat = 200
let glowGrad = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 0.18, green: 0.56, blue: 1.0, alpha: 0.18),
        CGColor(red: 0.18, green: 0.56, blue: 1.0, alpha: 0)
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    glowGrad,
    startCenter: CGPoint(x: centerX, y: centerY), startRadius: 0,
    endCenter: CGPoint(x: centerX, y: centerY), endRadius: 180,
    options: []
)
ctx.restoreGState()

// Arrow: shaft + chevron between the two icon slots (150,200) and (450,200).
// Icons are 128 px wide, so leave ~80 px clearance on each side → shaft from
// x=230 to x=370. Stroke + tip in soft white so it stays subordinate.
let arrowStartX: CGFloat = 230
let arrowEndX: CGFloat = 370
let arrowY: CGFloat = 200

ctx.setStrokeColor(white80)
ctx.setLineWidth(3)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: arrowStartX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
ctx.strokePath()

// Chevron tip
ctx.setStrokeColor(white80)
ctx.setLineWidth(3)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let tipX = arrowEndX
let tipSize: CGFloat = 14
ctx.move(to: CGPoint(x: tipX - tipSize, y: arrowY + tipSize))
ctx.addLine(to: CGPoint(x: tipX, y: arrowY))
ctx.addLine(to: CGPoint(x: tipX - tipSize, y: arrowY - tipSize))
ctx.strokePath()

// "MARKZZY" wordmark up top — small, tracked uppercase, accent-blue.
let wordmark = NSAttributedString(
    string: "MARKZZY",
    attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .bold),
        .foregroundColor: NSColor(cgColor: blue) ?? .white,
        .kern: 4.0,
    ]
)
let wmSize = wordmark.size()
wordmark.draw(at: NSPoint(x: (width - wmSize.width) / 2, y: height - 50))

// "Drag Markzzy to your Applications folder" subtitle below the arrow.
let hint = NSAttributedString(
    string: "Drag Markzzy to your Applications folder",
    attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(cgColor: white80) ?? .white,
    ]
)
let hintSize = hint.size()
hint.draw(at: NSPoint(x: (width - hintSize.width) / 2, y: 110))

// Tiny version disclaimer at the bottom — friendly, low contrast.
let footer = NSAttributedString(
    string: "macOS 14 or later · Continuity Camera supported",
    attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor(cgColor: white35) ?? .white,
    ]
)
let footerSize = footer.size()
footer.draw(at: NSPoint(x: (width - footerSize.width) / 2, y: 60))

image.unlockFocus()

// Write PNG
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("png encode failed\n", stderr)
    exit(1)
}
let outURL = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
try png.write(to: outURL)
print("wrote \(outPath) (\(png.count) bytes)")
