// Lays out the Product Hunt gallery images and thumbnail (media/producthunt) and the site's share image
// (assets/og.png) from the stills of the real panel that `demo/record.sh stills` captures, adding the words.
// Usage: swift demo/gallery.swift build/demo/stills
import AppKit

struct StillInfo: Decodable {
    let name: String
    let stage: CGSize
    /// The panel's card on the stage, from its top-left corner, in points.
    let card: CGRect?
}

let repository = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
guard CommandLine.arguments.count == 2 else {
    print("usage: swift demo/gallery.swift <stills folder>")
    exit(1)
}
let stillsFolder = URL(fileURLWithPath: CommandLine.arguments[1])
let infos = try JSONDecoder().decode([StillInfo].self, from: Data(contentsOf: stillsFolder.appendingPathComponent("manifest.json")))
let galleryFolder = repository.appendingPathComponent("media/producthunt")
try FileManager.default.createDirectory(at: galleryFolder, withIntermediateDirectories: true)
let icon = NSImage(contentsOf: repository.appendingPathComponent("icon/AppIcon-1024.png"))!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let amber = color(0xFFB443)
let soft = NSColor.white.withAlphaComponent(0.78)

/// An sRGB image of `width`×`height` pixels, drawn with AppKit. Positions are from the top-left corner.
final class Canvas {
    let width: CGFloat
    let height: CGFloat
    private let context: CGContext

    init(width: Int, height: Int) {
        self.width = CGFloat(width)
        self.height = CGFloat(height)
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    }

    func rect(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: x, y: self.height - top - height, width: width, height: height)
    }

    /// Fills the canvas with a still, which has the canvas's aspect ratio. Returns its scale, in pixels per point.
    func drawStill(_ info: StillInfo) -> CGFloat {
        let image = NSImage(contentsOf: stillsFolder.appendingPathComponent(info.name + ".png"))!
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        return width / info.stage.width
    }

    /// Draws `markup` centred in a column, *amber* between asterisks. Returns the bottom of the text.
    @discardableResult
    func text(_ markup: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white,
              top: CGFloat, x: CGFloat? = nil, width: CGFloat? = nil, alignment: NSTextAlignment = .center,
              lineSpacing: CGFloat = 0) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = lineSpacing
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let output = NSMutableAttributedString()
        for (index, piece) in markup.components(separatedBy: "*").enumerated() {
            output.append(NSAttributedString(string: piece, attributes: [
                .font: font, .foregroundColor: index % 2 == 1 ? amber : color, .paragraphStyle: paragraph,
            ]))
        }
        let columnWidth = width ?? self.width - 120
        let bounds = output.boundingRect(with: NSSize(width: columnWidth, height: 1000), options: .usesLineFragmentOrigin)
        let frame = rect(x: x ?? (self.width - columnWidth) / 2, top: top, width: columnWidth, height: ceil(bounds.height))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 12
        shadow.set()
        output.draw(with: frame, options: .usesLineFragmentOrigin)
        NSGraphicsContext.restoreGraphicsState()
        return top + ceil(bounds.height)
    }

    func write(_ url: URL) throws {
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        print("Wrote \(url.path)")
    }
}

func still(_ name: String) -> StillInfo {
    guard let info = infos.first(where: { $0.name == name }) else { fatalError("No still named \(name)") }
    return info
}

/// The card's top and bottom on the canvas, in pixels.
func cardEdges(_ info: StillInfo, scale: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
    let card = info.card!
    return (card.minY * scale, card.maxY * scale)
}

// MARK: Product Hunt gallery, 1270×760

do {
    let canvas = Canvas(width: 1270, height: 760)
    let info = still("hero")
    _ = canvas.drawStill(info)
    canvas.text("Flip to any window, tab or app", size: 56, weight: .bold, top: 40)
    canvas.text("A Spotlight-style switcher for macOS: *⌘Space*, a few letters, *Return*.", size: 25, color: soft, top: 116)
    try canvas.write(galleryFolder.appendingPathComponent("1-windows-tabs-apps.png"))
}

do {
    let canvas = Canvas(width: 1270, height: 760)
    let info = still("tabs")
    let card = cardEdges(info, scale: canvas.drawStill(info))
    let bottom = canvas.text("Your browser tabs too, even by address", size: 52, weight: .bold, top: 60)
    canvas.text("Chrome, Safari, Arc, Brave, Edge, Vivaldi and Chromium.\nEach browser window is listed as its tabs, current tab first.",
                size: 24, color: soft, top: bottom + 18, lineSpacing: 4)
    canvas.text("“jira” matches the address, so it finds Jira tabs whatever their titles say", size: 22,
                color: NSColor.white.withAlphaComponent(0.6), top: card.bottom + 56)
    try canvas.write(galleryFolder.appendingPathComponent("2-browser-tabs.png"))
}

do {
    let canvas = Canvas(width: 1270, height: 760)
    let info = still("apps")
    _ = canvas.drawStill(info)
    let bottom = canvas.text("Open apps that aren't running yet", size: 52, weight: .bold, top: 56)
    canvas.text("Installed apps are listed under Applications, below the matching\nwindows and tabs. One shortcut for all three.",
                size: 24, color: soft, top: bottom + 18, lineSpacing: 4)
    try canvas.write(galleryFolder.appendingPathComponent("3-apps.png"))
}

do {
    let canvas = Canvas(width: 1270, height: 760)
    _ = canvas.drawStill(still("plain"))
    icon.draw(in: canvas.rect(x: (canvas.width - 132) / 2, top: 74, width: 132, height: 132))
    canvas.text("Free, open source and private", size: 52, weight: .bold, top: 214)
    let tiles = [
        ("No network, no tracking", "No accounts and no analytics. Window titles and tabs never leave your Mac."),
        ("MIT licensed", "Every line is on GitHub. Read it, or build it yourself with one command."),
        ("Native and light", "A small Swift app with no dependencies, idle at 0% CPU until you call it."),
        ("Free download", "macOS 14 or later, Apple silicon and Intel. No account, no trial, no upsell."),
    ]
    let tileWidth: CGFloat = 495, tileHeight: CGFloat = 138, gap: CGFloat = 20
    let left = (canvas.width - 2 * tileWidth - gap) / 2
    for (index, tile) in tiles.enumerated() {
        let x = left + CGFloat(index % 2) * (tileWidth + gap)
        let top = 310 + CGFloat(index / 2) * (tileHeight + gap)
        let shape = NSBezierPath(roundedRect: canvas.rect(x: x, top: top, width: tileWidth, height: tileHeight), xRadius: 22, yRadius: 22)
        NSColor.white.withAlphaComponent(0.07).setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        shape.lineWidth = 1.5
        shape.stroke()
        let titleBottom = canvas.text(tile.0, size: 27, weight: .semibold, color: amber, top: top + 26, x: x + 30,
                                      width: tileWidth - 60, alignment: .left)
        canvas.text(tile.1, size: 20, color: soft, top: titleBottom + 10, x: x + 30, width: tileWidth - 60,
                    alignment: .left, lineSpacing: 3)
    }
    canvas.text("github.com/aftab404/lightswitch", size: 26, weight: .semibold, top: 310 + 2 * tileHeight + gap + 40)
    try canvas.write(galleryFolder.appendingPathComponent("4-open-source.png"))
}

// MARK: Product Hunt thumbnail, 240×240

do {
    let canvas = Canvas(width: 240, height: 240)
    // The icon's transparent margin, less a little, so the shape fills more of the square without clipping its shadow.
    icon.draw(in: NSRect(x: -8, y: -8, width: 256, height: 256))
    try canvas.write(galleryFolder.appendingPathComponent("thumbnail.png"))
}

// MARK: Share image, 1200×630

do {
    let canvas = Canvas(width: 1200, height: 630)
    _ = canvas.drawStill(still("og"))
    let left: CGFloat = 70, column: CGFloat = 380
    icon.draw(in: canvas.rect(x: left - 12, top: 112, width: 124, height: 124))
    var bottom = canvas.text("Lightswitch", size: 64, weight: .bold, top: 244, x: left, width: column, alignment: .left)
    bottom = canvas.text("Flip to any window, tab or app on your Mac.", size: 30, weight: .medium, color: soft,
                         top: bottom + 14, x: left, width: column, alignment: .left, lineSpacing: 2)
    canvas.text("*⌘Space*, a few letters, *Return*", size: 24, color: soft, top: bottom + 24, x: left, width: column,
                alignment: .left)
    try canvas.write(repository.appendingPathComponent("assets/og.png"))
}
