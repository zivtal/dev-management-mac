import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("usage: swift Tools/GenerateDevReinstallerAppIcon.swift <AppIcon.appiconset>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func layerPath(size: CGFloat, centerY: CGFloat) -> NSBezierPath {
    let centerX = size / 2
    let halfWidth = size * 0.30
    let halfHeight = size * 0.145
    let path = NSBezierPath()
    path.move(to: NSPoint(x: centerX, y: centerY + halfHeight))
    path.line(to: NSPoint(x: centerX + halfWidth, y: centerY))
    path.line(to: NSPoint(x: centerX, y: centerY - halfHeight))
    path.line(to: NSPoint(x: centerX - halfWidth, y: centerY))
    path.close()
    path.lineJoinStyle = .round
    return path
}

func generateIcon(pixelSize: Int) throws {
    let size = CGFloat(pixelSize)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    NSGraphicsContext.current?.imageInterpolation = .high
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    let inset = size * 0.045
    let backgroundPath = NSBezierPath(
        roundedRect: canvas.insetBy(dx: inset, dy: inset),
        xRadius: size * 0.22,
        yRadius: size * 0.22
    )
    let gradient = NSGradient(colors: [
        color(86, 67, 226),
        color(31, 127, 244),
        color(18, 176, 224)
    ])!
    gradient.draw(in: backgroundPath, angle: -52)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = size * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.018)
    shadow.set()

    let layers: [(CGFloat, CGFloat)] = [(0.36, 0.50), (0.49, 0.70), (0.62, 0.98)]
    for (centerRatio, opacity) in layers {
        let path = layerPath(size: size, centerY: size * centerRatio)
        NSColor.white.withAlphaComponent(opacity).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(min(1, opacity + 0.15)).setStroke()
        path.lineWidth = max(0.8, size * 0.012)
        path.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "DevReinstallerIcon", code: 1)
    }
    try png.write(to: outputURL.appendingPathComponent("AppIcon-\(pixelSize).png"), options: .atomic)
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    try generateIcon(pixelSize: size)
}
