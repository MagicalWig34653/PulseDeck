// Captures one on-screen window of a running app to a PNG (used for README screenshots).
//
// Usage: swift capture-window.swift <owner-name> <output.png> [min-width] [max-width] [any-layer]
// Picks the largest normal-level window owned by <owner-name> whose width lies within the
// optional bounds, then calls `screencapture -l <window-id>`. With `any-layer`, windows above the
// normal level (e.g. a menu bar extra's panel) are considered too.

import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: capture-window.swift <owner> <output.png> [min-width] [max-width]\n".utf8))
    exit(64)
}
let owner = arguments[1]
let output = arguments[2]
let minWidth = arguments.count > 3 ? Double(arguments[3]) ?? 0 : 0
let maxWidth = arguments.count > 4 ? Double(arguments[4]) ?? .infinity : .infinity
let anyLayer = arguments.count > 5 && arguments[5] == "any-layer"

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []

var best: (id: CGWindowID, area: Double)?
for window in windows {
    guard window[kCGWindowOwnerName as String] as? String == owner,
          anyLayer || window[kCGWindowLayer as String] as? Int == 0,
          let id = window[kCGWindowNumber as String] as? CGWindowID,
          let bounds = window[kCGWindowBounds as String] as? [String: Double],
          let width = bounds["Width"], let height = bounds["Height"],
          width >= minWidth, width <= maxWidth
    else { continue }
    print("candidate window \(id): \(Int(width))×\(Int(height))")
    let area = width * height
    if let current = best, current.area >= area { continue }
    best = (id, area)
}

guard let best else {
    FileHandle.standardError.write(Data("no window found for \(owner)\n".utf8))
    exit(1)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
process.arguments = ["-x", "-l", String(best.id), output]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
