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

let brandTop = NSColor(srgbRed: 0.251, green: 0.353, blue: 0.961, alpha: 1)
let brandBottom = NSColor(srgbRed: 0.035, green: 0.639, blue: 0.706, alpha: 1)

func drawBackground() {
    // Soft, light backdrop so Finder's dark icon labels stay legible.
    let backdrop = NSGradient(
        starting: NSColor(srgbRed: 0.965, green: 0.972, blue: 1.0, alpha: 1),
        ending: NSColor(srgbRed: 0.918, green: 0.965, blue: 0.972, alpha: 1)
    )
    backdrop?.draw(in: NSRect(origin: .zero, size: canvas), angle: -90)

    let baseline = canvas.height - appIconCenter.y
    let accent = NSColor(srgbRed: 0.145, green: 0.494, blue: 0.835, alpha: 0.9)

    // Faint baseline behind the icons, echoing the app icon's pulse line.
    let track = NSBezierPath()
    track.move(to: NSPoint(x: 0, y: baseline))
    track.line(to: NSPoint(x: canvas.width, y: baseline))
    track.lineWidth = 2
    brandTop.withAlphaComponent(0.12).setStroke()
    track.stroke()

    // The arrow from the app to Applications is itself a heartbeat: flat, one beat, flat,
    // then an arrowhead.
    let startX = appIconCenter.x + 92
    let endX = applicationsCenter.x - 92
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: startX, y: baseline))
    arrow.line(to: NSPoint(x: startX + 34, y: baseline))
    arrow.line(to: NSPoint(x: startX + 50, y: baseline + 30))
    arrow.line(to: NSPoint(x: startX + 70, y: baseline - 36))
    arrow.line(to: NSPoint(x: startX + 86, y: baseline + 14))
    arrow.line(to: NSPoint(x: startX + 96, y: baseline))
    arrow.line(to: NSPoint(x: endX, y: baseline))
    arrow.move(to: NSPoint(x: endX - 14, y: baseline + 13))
    arrow.line(to: NSPoint(x: endX, y: baseline))
    arrow.line(to: NSPoint(x: endX - 14, y: baseline - 13))
    arrow.lineWidth = 4.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    accent.setStroke()
    arrow.stroke()

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
