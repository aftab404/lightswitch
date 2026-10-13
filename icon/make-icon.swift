// Renders Lightswitch's app icon and packs it into AppIcon.icns.
// Usage: swift icon/make-icon.swift   (writes icon/AppIcon.icns)
//
// A wall light switch flipped on, glowing warm against a dark backdrop: "light" as in turning the
// lights on, and as in easy / lightweight.
import AppKit

let canvas: CGFloat = 1024
let center = NSPoint(x: 512, y: 512)
let iconDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func withShadow(_ shadowColor: NSColor, blur: CGFloat, offsetY: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: offsetY)
    shadow.shadowColor = shadowColor
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func clipped(to path: NSBezierPath, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func centeredRect(width: CGFloat, height: CGFloat) -> NSRect {
    NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
}

func drawScrew(at point: NSPoint) {
    let head = NSBezierPath(ovalIn: NSRect(x: point.x - 17, y: point.y - 17, width: 34, height: 34))
    withShadow(NSColor.black.withAlphaComponent(0.18), blur: 4, offsetY: -2) {
        NSGradient(starting: color(0xF4F1EA), ending: color(0xCFC8B8))!.draw(in: head, angle: -90)
    }
    let slot = NSBezierPath()
    let angle = CGFloat.pi * 0.14
    slot.move(to: NSPoint(x: point.x - cos(angle) * 11, y: point.y - sin(angle) * 11))
    slot.line(to: NSPoint(x: point.x + cos(angle) * 11, y: point.y + sin(angle) * 11))
    slot.lineWidth = 4.5
    slot.lineCapStyle = .round
    color(0xA39B8A).setStroke()
    slot.stroke()
}

func renderIcon() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // Body: standard macOS grid, 824pt shape with a 185pt corner radius centred on a 1024 canvas.
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    withShadow(NSColor.black.withAlphaComponent(0.3), blur: 28, offsetY: -12) {
        color(0x1A1C30).setFill()
        body.fill()
    }

    clipped(to: body) {
        // Night-time backdrop.
        NSGradient(starting: color(0x272B45), ending: color(0x0D0E1A))!.draw(in: body.bounds, angle: -90)
        // Warm light spilling out around the switch, added on top so it brightens rather than muddies.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .plusLighter
        NSGradient(colors: [color(0xFFB443, 0.95), color(0xFF9A2E, 0.5), color(0xFF8A2A, 0.14), color(0xFF8A2A, 0)],
                   atLocations: [0, 0.42, 0.72, 1], colorSpace: .sRGB)!
            .draw(fromCenter: NSPoint(x: 512, y: 540), radius: 0,
                  toCenter: NSPoint(x: 512, y: 540), radius: 470, options: [])
        NSGraphicsContext.restoreGraphicsState()

        // Wall plate.
        let plateRect = centeredRect(width: 372, height: 552)
        let plate = NSBezierPath(roundedRect: plateRect, xRadius: 62, yRadius: 62)
        withShadow(NSColor.black.withAlphaComponent(0.45), blur: 48, offsetY: -20) {
            color(0xF6F2E9).setFill()
            plate.fill()
        }
        NSGradient(starting: color(0xFFFEFA), ending: color(0xE8E2D4))!.draw(in: plate, angle: -90)
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let plateEdge = NSBezierPath(roundedRect: plateRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 61, yRadius: 61)
        plateEdge.lineWidth = 3
        plateEdge.stroke()

        drawScrew(at: NSPoint(x: 512, y: plateRect.maxY - 52))
        drawScrew(at: NSPoint(x: 512, y: plateRect.minY + 52))

        // Recess the rocker sits in.
        let recessRect = centeredRect(width: 216, height: 346)
        let recess = NSBezierPath(roundedRect: recessRect, xRadius: 40, yRadius: 40)
        NSGradient(starting: color(0xC9C1AF), ending: color(0xDDD6C7))!.draw(in: recess, angle: -90)

        // Rocker, switched on: the top half is pressed in, the bottom half stands proud.
        let rockerRect = recessRect.insetBy(dx: 13, dy: 13)
        let rocker = NSBezierPath(roundedRect: rockerRect, xRadius: 30, yRadius: 30)
        withShadow(NSColor.black.withAlphaComponent(0.28), blur: 16, offsetY: -9) {
            color(0xF3EFE6).setFill()
            rocker.fill()
        }
        clipped(to: rocker) {
            let upper = NSRect(x: rockerRect.minX, y: center.y, width: rockerRect.width, height: rockerRect.maxY - center.y)
            let lower = NSRect(x: rockerRect.minX, y: rockerRect.minY, width: rockerRect.width, height: center.y - rockerRect.minY)
            NSGradient(starting: color(0xDCD5C6), ending: color(0xF2EEE4))!.draw(in: upper, angle: -90)
            NSGradient(starting: color(0xFFFFFF), ending: color(0xEDE8DC))!.draw(in: lower, angle: -90)
        }
        let crease = NSBezierPath()
        crease.move(to: NSPoint(x: rockerRect.minX, y: center.y))
        crease.line(to: NSPoint(x: rockerRect.maxX, y: center.y))
        crease.lineWidth = 3
        color(0xC4BCAA).setStroke()
        crease.stroke()

        // "On" indicator.
        let led = NSBezierPath(roundedRect: NSRect(x: 512 - 30, y: rockerRect.maxY - 58, width: 60, height: 15),
                               xRadius: 7.5, yRadius: 7.5)
        withShadow(color(0xFFAA22, 0.9), blur: 22, offsetY: 0) {
            color(0xFFB733).setFill()
            led.fill()
        }

        // Soft light from the top.
        NSGradient(starting: NSColor.white.withAlphaComponent(0.12), ending: NSColor.white.withAlphaComponent(0))!
            .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    }

    // Fine light edge around the body.
    NSColor.white.withAlphaComponent(0.16).setStroke()
    body.lineWidth = 3
    body.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = iconDir.appendingPathComponent("AppIcon-1024.png")
try renderIcon().representation(using: .png, properties: [:])!.write(to: master)

func run(_ tool: String, _ args: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: tool, code: Int(process.terminationStatus)) }
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try run("/usr/bin/sips", ["-z", "\(pixels)", "\(pixels)", master.path, "--out", iconset.appendingPathComponent(name).path])
    }
}
try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", iconDir.appendingPathComponent("AppIcon.icns").path])
print("Wrote \(iconDir.appendingPathComponent("AppIcon.icns").path)")
