#!/usr/bin/env swift

import AppKit

// Generate macOS app icon from SF Symbol with gradient background

func generateIcon(size: Int, scale: Int = 1) -> NSImage {
    let pixelSize = size * scale
    let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))

    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    let cornerRadius = CGFloat(pixelSize) * 0.22 // macOS icon corner radius

    // Background: blue gradient
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    let gradient = NSGradient(colors: [
        NSColor(red: 0.18, green: 0.45, blue: 0.95, alpha: 1.0), // bright blue top
        NSColor(red: 0.25, green: 0.35, blue: 0.85, alpha: 1.0), // mid blue
        NSColor(red: 0.15, green: 0.25, blue: 0.75, alpha: 1.0), // deeper blue bottom
    ], atLocations: [0.0, 0.5, 1.0], colorSpace: .deviceRGB)!

    gradient.draw(in: path, angle: -90)

    // Subtle inner glow
    let innerGlow = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: cornerRadius - 1, yRadius: cornerRadius - 1)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    innerGlow.lineWidth = CGFloat(pixelSize) * 0.01
    innerGlow.stroke()

    // SF Symbol: doc.on.clipboard
    let symbolSize = CGFloat(pixelSize) * 0.52
    let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let symbolRect = symbol.size
        let x = (CGFloat(pixelSize) - symbolRect.width) / 2
        let y = (CGFloat(pixelSize) - symbolRect.height) / 2

        // Draw white symbol with slight shadow
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -CGFloat(pixelSize) * 0.015)
        shadow.shadowBlurRadius = CGFloat(pixelSize) * 0.03
        shadow.set()

        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        symbol.draw(in: NSRect(origin: .zero, size: symbol.size), from: .zero, operation: .destinationIn, fraction: 1.0)
        tinted.unlockFocus()

        tinted.draw(in: NSRect(x: x, y: y, width: symbolRect.width, height: symbolRect.height),
                    from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
        print("❌ Failed to create PNG for \(path)")
        return
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("✅ \(path)")
    } catch {
        print("❌ \(error)")
    }
}

func createIconset() {
    let iconsetDir = "AppIcon.iconset"
    try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

    let sizes: [(name: String, size: Int, scale: Int)] = [
        ("icon_16x16", 16, 1),
        ("icon_16x16@2x", 16, 2),
        ("icon_32x32", 32, 1),
        ("icon_32x32@2x", 32, 2),
        ("icon_128x128", 128, 1),
        ("icon_128x128@2x", 128, 2),
        ("icon_256x256", 256, 1),
        ("icon_256x256@2x", 256, 2),
        ("icon_512x512", 512, 1),
        ("icon_512x512@2x", 512, 2),
    ]

    for entry in sizes {
        let image = generateIcon(size: entry.size, scale: entry.scale)
        savePNG(image, to: "\(iconsetDir)/\(entry.name).png")
    }

    // Convert iconset to icns
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconsetDir, "-o", "AppIcon.icns"]
    try? process.run()
    process.waitUntilExit()

    if process.terminationStatus == 0 {
        print("\n🎉 AppIcon.icns created successfully!")
        print("   Copy to SupportingFiles/AppIcon.icns")
    } else {
        print("\n❌ iconutil failed")
    }

    // Cleanup
    try? FileManager.default.removeItem(atPath: iconsetDir)
}

print("Generating ClipSlop app icon...")
createIconset()
