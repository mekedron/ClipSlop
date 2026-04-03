#!/usr/bin/env swift

import AppKit

func generateIcon(pixelSize: Int) -> NSImage {
    let s = CGFloat(pixelSize)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let cornerRadius = s * 0.22

    // === Background gradient ===
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    let gradient = NSGradient(colors: [
        NSColor(red: 0.30, green: 0.55, blue: 1.0, alpha: 1.0),
        NSColor(red: 0.22, green: 0.38, blue: 0.90, alpha: 1.0),
        NSColor(red: 0.16, green: 0.28, blue: 0.78, alpha: 1.0),
    ], atLocations: [0.0, 0.5, 1.0], colorSpace: .deviceRGB)!
    gradient.draw(in: bgPath, angle: -90)

    // === Draw clipboard icon manually ===
    let cx = s * 0.5  // center x
    let cy = s * 0.48 // center y (slightly above center)

    // Clipboard board dimensions
    let boardW = s * 0.38
    let boardH = s * 0.46
    let boardR = s * 0.04 // corner radius
    let boardX = cx - boardW / 2
    let boardY = cy - boardH / 2

    // Shadow
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.015)
    shadow.shadowBlurRadius = s * 0.04
    shadow.set()

    // Board shape (rounded rect)
    let boardRect = NSRect(x: boardX, y: boardY, width: boardW, height: boardH)
    let boardPath = NSBezierPath(roundedRect: boardRect, xRadius: boardR, yRadius: boardR)
    NSColor.white.withAlphaComponent(0.95).setFill()
    boardPath.fill()

    // Remove shadow for details
    NSShadow().set()

    // Clip at top (the clipboard clip)
    let clipW = s * 0.16
    let clipH = s * 0.07
    let clipR = s * 0.025
    let clipX = cx - clipW / 2
    let clipY = boardY + boardH - clipH * 0.5

    let clipRect = NSRect(x: clipX, y: clipY, width: clipW, height: clipH)
    let clipPath = NSBezierPath(roundedRect: clipRect, xRadius: clipR, yRadius: clipR)
    NSColor.white.setFill()
    clipPath.fill()
    NSColor.white.withAlphaComponent(0.6).setStroke()
    clipPath.lineWidth = s * 0.006
    clipPath.stroke()

    // Inner clip circle (the hole)
    let holeSize = s * 0.04
    let holePath = NSBezierPath(ovalIn: NSRect(
        x: cx - holeSize / 2,
        y: clipY + clipH / 2 - holeSize / 2,
        width: holeSize,
        height: holeSize
    ))
    NSColor(red: 0.22, green: 0.38, blue: 0.90, alpha: 0.4).setFill()
    holePath.fill()

    // Text lines on the board
    let lineColor = NSColor(red: 0.25, green: 0.40, blue: 0.85, alpha: 0.35)
    lineColor.setFill()

    let lineH = s * 0.018
    let lineGap = s * 0.042
    let lineX = boardX + s * 0.05
    let lineMaxW = boardW - s * 0.10
    let firstLineY = boardY + boardH - s * 0.14

    let lineWidths: [CGFloat] = [1.0, 0.75, 0.85, 0.6, 0.9, 0.5]
    for (i, widthFraction) in lineWidths.enumerated() {
        let ly = firstLineY - CGFloat(i) * lineGap
        if ly < boardY + s * 0.03 { break }
        let lw = lineMaxW * widthFraction
        let lineRect = NSRect(x: lineX, y: ly, width: lw, height: lineH)
        NSBezierPath(roundedRect: lineRect, xRadius: lineH / 2, yRadius: lineH / 2).fill()
    }

    // === Small document overlay (bottom-right) ===
    let docW = s * 0.18
    let docH = s * 0.22
    let docR = s * 0.025
    let docX = cx + s * 0.06
    let docY = boardY - s * 0.04

    // Doc shadow
    let docShadow = NSShadow()
    docShadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
    docShadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    docShadow.shadowBlurRadius = s * 0.025
    docShadow.set()

    let docRect = NSRect(x: docX, y: docY, width: docW, height: docH)
    let docPath = NSBezierPath(roundedRect: docRect, xRadius: docR, yRadius: docR)
    NSColor.white.setFill()
    docPath.fill()

    NSShadow().set()

    // Doc corner fold
    let foldSize = s * 0.045
    let foldPath = NSBezierPath()
    foldPath.move(to: NSPoint(x: docX + docW - foldSize, y: docY + docH))
    foldPath.line(to: NSPoint(x: docX + docW, y: docY + docH - foldSize))
    foldPath.line(to: NSPoint(x: docX + docW, y: docY + docH))
    foldPath.close()
    NSColor(red: 0.25, green: 0.40, blue: 0.85, alpha: 0.15).setFill()
    foldPath.fill()

    // Doc lines
    let docLineColor = NSColor(red: 0.25, green: 0.40, blue: 0.85, alpha: 0.3)
    docLineColor.setFill()
    let dlH = s * 0.012
    let dlGap = s * 0.03
    let dlX = docX + s * 0.025
    let dlMaxW = docW - s * 0.05
    let dlFirstY = docY + docH - s * 0.055

    let dlWidths: [CGFloat] = [0.9, 0.65, 0.8, 0.5]
    for (i, wf) in dlWidths.enumerated() {
        let ly = dlFirstY - CGFloat(i) * dlGap
        if ly < docY + s * 0.02 { break }
        let lw = dlMaxW * wf
        NSBezierPath(roundedRect: NSRect(x: dlX, y: ly, width: lw, height: dlH),
                     xRadius: dlH / 2, yRadius: dlH / 2).fill()
    }

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { print("❌ \(path)"); return }
    try! png.write(to: URL(fileURLWithPath: path))
    print("✅ \(path)")
}

// Generate iconset
let iconsetDir = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

print("Generating ClipSlop app icon...")
for (name, px) in sizes {
    savePNG(generateIcon(pixelSize: px), to: "\(iconsetDir)/\(name).png")
}

// Also save a preview for README
savePNG(generateIcon(pixelSize: 512), to: "docs/icon.png")

// Convert to icns
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconsetDir, "-o", "SupportingFiles/AppIcon.icns"]
try! p.run()
p.waitUntilExit()

try? FileManager.default.removeItem(atPath: iconsetDir)
print(p.terminationStatus == 0 ? "\n🎉 AppIcon.icns + docs/icon.png created!" : "\n❌ iconutil failed")
