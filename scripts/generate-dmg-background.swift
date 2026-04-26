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

// Palette — drawn as CGColors for the gradient + arrow strokes, and as
// matching NSColors for text. Going through `NSColor(cgColor:)` was
// returning `.white` opaque in some contexts because the converter is
// fallible; building the NSColors directly removes that surprise.
let navyTop = CGColor(red: 0.07, green: 0.13, blue: 0.27, alpha: 1)  // #121F45
let navyBot = CGColor(red: 0.02, green: 0.05, blue: 0.12, alpha: 1)  // #060D1F
let arrowStroke = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.85)

let accentNS = NSColor(srgbRed: 0.45, green: 0.72, blue: 1.0, alpha: 1)   // bright accent for wordmark
let textPrimary = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95)
let textSecondary = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55)

// Vertical navy gradient
let cs = CGColorSpaceCreateDeviceRGB()
let grad = CGGradient(colorsSpace: cs, colors: [navyTop, navyBot] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: height), end: .zero, options: [])

// Cocoa Y is from BOTTOM. Vertical zones in this 400-tall canvas:
//   Y=370   wordmark "MARKZZY"
//   Y=320   hint "Drag Markzzy to your Applications folder"
//   Y=200   icons + arrow row (create-dmg places icons at y=200 too,
//           Finder coord = Y from top of content; 400/2 lines up).
//   Y=50    macOS version footer
// Hint used to be at Y=110 (below the icons in Cocoa coords) which
// translated to the icon-center row in Finder coords — Finder painted
// the icons over the text. Moving the hint above the icon row removes
// the collision entirely.

// NOTE on the missing aurora glow:
// Earlier versions had a soft blue radial glow centered behind the icon
// row. We removed it because Finder samples the BACKGROUND IMAGE's
// average luminance to decide label-text color (the icvp
// backgroundColor* keys are ignored when a backgroundImage is set).
// The glow lifted the average enough that Finder mis-classified the
// background as "light" and painted the labels in dark text — unreadable
// against the navy. Keeping the gradient uniformly dark guarantees a low
// average → Finder picks WHITE labels automatically. Sparkle / dmgbuild
// settings unchanged.

// Arrow shaft + chevron between the two icon slots (150,200) → (450,200).
// Icons are 128 px wide, so leave ~80 px clearance per side → shaft from
// x=230 to x=370. Sits exactly where the icon row will be — Finder paints
// the icons on top, the arrow peeks between them.
let arrowStartX: CGFloat = 230
let arrowEndX: CGFloat = 370
let arrowY: CGFloat = 200

ctx.setStrokeColor(arrowStroke)
ctx.setLineWidth(3)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: arrowStartX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
ctx.strokePath()

// Chevron tip
ctx.setLineJoin(.round)
let tipX = arrowEndX
let tipSize: CGFloat = 14
ctx.move(to: CGPoint(x: tipX - tipSize, y: arrowY + tipSize))
ctx.addLine(to: CGPoint(x: tipX, y: arrowY))
ctx.addLine(to: CGPoint(x: tipX - tipSize, y: arrowY - tipSize))
ctx.strokePath()

// "MARKZZY" wordmark at the very top — bold, tracked, accent-blue.
let wordmark = NSAttributedString(
    string: "MARKZZY",
    attributes: [
        .font: NSFont.systemFont(ofSize: 16, weight: .bold),
        .foregroundColor: accentNS,
        .kern: 5.0,
    ]
)
let wmSize = wordmark.size()
wordmark.draw(at: NSPoint(x: (width - wmSize.width) / 2, y: 360))

// "Drag Markzzy to your Applications folder" hint — ABOVE the icons,
// not below. Centered, bigger so it reads at glance, high contrast.
let hint = NSAttributedString(
    string: "Drag Markzzy to your Applications folder",
    attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: textPrimary,
    ]
)
let hintSize = hint.size()
hint.draw(at: NSPoint(x: (width - hintSize.width) / 2, y: 305))

// Icon labels ("Markzzy" / "Applications") are painted by Finder itself.
// scripts/dmgbuild-settings.py overrides the .DS_Store icvp
// `backgroundColorRed/Green/Blue` to dark navy, which Finder's contrast
// check reads → it picks WHITE label text. So we don't draw the labels
// here. Earlier revisions painted white labels at Y=118 to peek through
// Finder's default dark labels; that hack is gone now that the .DS_Store
// itself drives label color.

// Icon labels — painted INTO the PNG in bold white. Finder paints its
// own (dark) labels on top; ours sit just above Finder's so the dark
// reads as a tight drop-shadow underneath the white. We tried every
// official channel for forcing Finder's labels white (icvp
// backgroundColor* keys, dmgbuild settings, image-luminance heuristics)
// — none of them flip the label color when a backgroundImage is set.
// Painting white into the PNG is the only thing that actually shows.
let labelY: CGFloat = 118
let labelStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .bold),
    .foregroundColor: NSColor.white,
]
for (text, x) in [("Markzzy", CGFloat(150)), ("Applications", CGFloat(450))] {
    let attr = NSAttributedString(string: text, attributes: labelStyle)
    let s = attr.size()
    attr.draw(at: NSPoint(x: x - s.width / 2, y: labelY))
}

// Tiny system requirements footer near the bottom. Bumped up from y=35
// (felt cramped against the bottom edge) to y=55 for breathing room.
let footer = NSAttributedString(
    string: "macOS 14 or later · Continuity Camera supported",
    attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .regular),
        .foregroundColor: textSecondary,
    ]
)
let footerSize = footer.size()
footer.draw(at: NSPoint(x: (width - footerSize.width) / 2, y: 55))

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
