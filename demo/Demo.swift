// Scripted session for screen recordings, compiled only by `./build.sh demo` (see demo/record.sh).
// It drives the real switcher with sample windows in front of a neutral backdrop, so no real
// window titles end up in a published video.
import AppKit

@MainActor
enum Demo {
    private static let stageSize = NSSize(width: 840, height: 560)
    private static var backdrop: NSWindow?

    static func run(app: AppDelegate) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let screen = NSScreen.screens[0]
        let stage = stageFrame(on: screen)
        backdrop = makeBackdrop(frame: stage)

        // screencapture -R takes points from the main display's top-left corner.
        let top = screen.frame.maxY - stage.maxY
        report("RECT \(Int(stage.minX)),\(Int(top)),\(Int(stage.width)),\(Int(stage.height))")
        Task { await play(app, on: screen) }
    }

    private static func play(_ app: AppDelegate, on screen: NSScreen) async {
        // Park the pointer in the bottom-right corner, outside the recorded area, and put it back afterwards.
        let pointer = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(CGPoint(x: screen.frame.maxX - 2, y: screen.frame.maxY - 2))

        await pause(3) // gives record.sh time to start the recorder
        app.show(on: screen, items: sampleWindows())
        report("SHOW \(Date().timeIntervalSince1970)")
        await pause(1.4)
        await type("rdmp")
        await pause(1.6)
        press(#selector(NSResponder.cancelOperation(_:))) // Esc clears the query
        await pause(0.5)
        await type("notes")
        await pause(0.7)
        press(#selector(NSResponder.insertTab(_:)))
        await pause(1.4)
        press(#selector(NSResponder.cancelOperation(_:)))
        await pause(0.5)
        await type("pr light")
        await pause(1.8)
        app.hide() // Return, without actually focusing anything
        report("DONE \(Date().timeIntervalSince1970)")
        await pause(6) // past the end of the recording
        if let pointer { CGWarpMouseCursorPosition(pointer) }
        NSApp.terminate(nil)
    }

    /// Types through the search field's editor, exactly like keystrokes would.
    private static func type(_ text: String) async {
        for character in text {
            searchEditor?.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            await pause(0.14)
        }
    }

    private static func press(_ command: Selector) {
        searchEditor?.doCommand(by: command)
    }

    private static var searchEditor: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func report(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    // MARK: Stage

    private static func stageFrame(on screen: NSScreen) -> NSRect {
        let top = Layout.cardTop(on: screen) + 72
        return NSRect(x: (screen.visibleFrame.midX - stageSize.width / 2).rounded(),
                      y: (top - stageSize.height).rounded(),
                      width: stageSize.width, height: stageSize.height)
    }

    private static func makeBackdrop(frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = BackdropView()
        window.orderFrontRegardless()
        return window
    }

    private static func sampleWindows() -> [WindowItem] {
        let samples: [(title: String, app: String, path: String, minimized: Bool)] = [
            ("lightswitch — zsh — 120×40", "Terminal", "/System/Applications/Utilities/Terminal.app", false),
            ("Q4 roadmap", "Notes", "/System/Applications/Notes.app", false),
            ("Pull requests · aftab404/lightswitch", "Safari", "/Applications/Safari.app", false),
            ("Inbox — 3 unread", "Mail", "/System/Applications/Mail.app", false),
            ("design-review.pdf", "Preview", "/System/Applications/Preview.app", false),
            ("Team offsite — October", "Calendar", "/System/Applications/Calendar.app", false),
            ("Weekly sync notes", "Notes", "/System/Applications/Notes.app", true),
            ("Downloads", "Finder", "/System/Library/CoreServices/Finder.app", false),
        ]
        // Any element will do: sample rows are never focused, and nil would mark them as app-only rows.
        let placeholder = AXUIElementCreateApplication(getpid())
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        return samples.enumerated().map { index, sample in
            // Giving the top row the frontmost app's pid makes it "the window you're in", as in real use.
            WindowItem(id: "demo-\(index)", pid: index == 0 ? frontmost : 0, appName: sample.app, title: sample.title,
                       element: placeholder, isMinimized: sample.minimized, isAppHidden: false,
                       icon: icon(of: sample.path))
        }
    }

    /// The app's own icon file, so the recording shows full-colour icons whatever the system icon style.
    private static func icon(of appPath: String) -> NSImage {
        let bundle = Bundle(path: appPath)
        if let name = bundle?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let url = bundle?.url(forResource: (name as NSString).deletingPathExtension, withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSWorkspace.shared.icon(forFile: appPath)
    }
}

/// A dusky "desktop" with a few blurred-looking windows for the glass panel to sit on.
private final class BackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [color(0x2C2B5E), color(0x1A1C41), color(0x3A2350), color(0x0E0F22)],
                   atLocations: [0, 0.45, 0.75, 1], colorSpace: .sRGB)!
            .draw(in: bounds, angle: -40)
        let glowCenter = NSPoint(x: bounds.midX, y: bounds.midY + 40)
        NSGradient(starting: color(0xFFAA46, 0.32), ending: color(0xFFAA46, 0))!
            .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: bounds.width * 0.45, options: [])

        let windows = [
            NSRect(x: bounds.width * 0.04, y: bounds.height * 0.3, width: bounds.width * 0.4, height: bounds.height * 0.55),
            NSRect(x: bounds.width * 0.58, y: bounds.height * 0.1, width: bounds.width * 0.37, height: bounds.height * 0.62),
            NSRect(x: bounds.width * 0.28, y: -bounds.height * 0.1, width: bounds.width * 0.44, height: bounds.height * 0.35),
        ]
        for rect in windows {
            let shape = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
            NSColor.white.withAlphaComponent(0.09).setFill()
            shape.fill()
            NSColor.white.withAlphaComponent(0.16).setStroke()
            shape.stroke()
            for index in 0..<3 {
                NSColor.white.withAlphaComponent(0.35).setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.minX + 16 + CGFloat(index) * 18, y: rect.maxY - 24, width: 10, height: 10)).fill()
            }
            NSColor.white.withAlphaComponent(0.1).setFill()
            for line in 0..<4 {
                let width = rect.width * [0.7, 0.5, 0.62, 0.4][line]
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 18, y: rect.maxY - 62 - CGFloat(line) * 30, width: width, height: 12),
                             xRadius: 6, yRadius: 6).fill()
            }
        }
    }

    private func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
