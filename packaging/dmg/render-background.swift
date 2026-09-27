// Renders the DMG window background at 1x and 2x with AppKit, so the text uses the
// system font and the Retina variant is pixel-exact.
//
// Usage: swift render-background.swift <output-directory>
// Writes background.png (660×400) and background@2x.png (1320×800).
//
// Icon positions must match packaging/dmg/settings.py (Finder coordinates are top-left based).

import AppKit

let canvas = NSSize(width: 660, height: 400)
let appIconCenter = NSPoint(x: 170, y: 185)
let applicationsCenter = NSPoint(x: 490, y: 185)

/// Converts a top-left based Finder coordinate to AppKit's bottom-left drawing space.
func flipped(_ point: NSPoint) -> NSPoint {
    NSPoint(x: point.x, y: canvas.height - point.y)
}

let brandTop = NSColor(srgbRed: 0.251, green: 0.353, blue: 0.961, alpha: 1)
let brandBottom = NSColor(srgbRed: 0.035, green: 0.639, blue: 0.706, alpha: 1)

func drawBackground() {
    // Soft, light backdrop so Finder's dark icon labels stay legible.
    let backdrop = NSGradient(
        starting: NSColor(srgbRed: 0.965, green: 0.972, blue: 1.0, alpha: 1),
        ending: NSColor(srgbRed: 0.918, green: 0.965, blue: 0.972, alpha: 1)
    )
    backdrop?.draw(in: NSRect(origin: .zero, size: canvas), angle: -90)

    // Faint pulse waveform across the window, echoing the app icon.
    let pulse = NSBezierPath()
    let baseline = canvas.height - 185
    pulse.move(to: NSPoint(x: -10, y: baseline))
    pulse.line(to: NSPoint(x: 275, y: baseline))
    pulse.line(to: NSPoint(x: 300, y: baseline + 46))
    pulse.line(to: NSPoint(x: 332, y: baseline - 58))
    pulse.line(to: NSPoint(x: 360, y: baseline + 26))
    pulse.line(to: NSPoint(x: 378, y: baseline))
    pulse.line(to: NSPoint(x: canvas.width + 10, y: baseline))
    pulse.lineWidth = 3
    pulse.lineCapStyle = .round
    pulse.lineJoinStyle = .round
    brandTop.withAlphaComponent(0.18).setStroke()
    pulse.stroke()

    // Arrow from the app to the Applications folder.
    let start = flipped(NSPoint(x: appIconCenter.x + 92, y: appIconCenter.y))
    let end = flipped(NSPoint(x: applicationsCenter.x - 92, y: applicationsCenter.y))
    let shaft = NSBezierPath()
    shaft.move(to: start)
    shaft.line(to: end)
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end.x - 16, y: end.y + 14))
    head.line(to: end)
    head.line(to: NSPoint(x: end.x - 16, y: end.y - 14))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    let arrowColor = NSColor(srgbRed: 0.145, green: 0.494, blue: 0.835, alpha: 0.85)
    arrowColor.setStroke()
    shaft.stroke()
    head.stroke()

    // Title and instruction.
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let title = NSAttributedString(string: "PulseDeck", attributes: [
        .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
        .foregroundColor: NSColor(srgbRed: 0.106, green: 0.137, blue: 0.251, alpha: 1),
        .paragraphStyle: paragraph,
    ])
    title.draw(in: NSRect(x: 0, y: canvas.height - 62, width: canvas.width, height: 34))

    let caption = NSAttributedString(string: "Drag PulseDeck to Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.33, green: 0.37, blue: 0.47, alpha: 1),
        .paragraphStyle: paragraph,
    ])
    caption.draw(in: NSRect(x: 0, y: 44, width: canvas.width, height: 20))
}

func render(scale: CGFloat, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.width * scale),
        pixelsHigh: Int(canvas.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    rep.size = canvas // draw in points; the rep's pixel size provides the scale
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawBackground()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-background.swift <output-directory>\n".utf8))
    exit(64)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try render(scale: 1, to: directory.appendingPathComponent("background.png"))
try render(scale: 2, to: directory.appendingPathComponent("background@2x.png"))
