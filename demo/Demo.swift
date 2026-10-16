// Scripted session for screen recordings, compiled only by `./build.sh demo` (see demo/record.sh).
// It drives the real switcher with sample windows, browser tabs and apps on a made-up desktop, so no real window
// titles, tabs or apps end up in a published video. Return plays out on that desktop: the window you're in changes.
// With `--stills <folder>` it poses the panel for the still images demo/gallery.swift lays out instead, waiting
// for demo/record.sh to capture each one.
import AppKit

@MainActor
enum Demo {
    private static let stageSize = NSSize(width: 760, height: 620)
    /// Between the stage's top edge and the panel's, where the captions go.
    private static let captionBand: CGFloat = 84

    private struct Still {
        let name: String
        let query: String
        var selectsLast = false
        var showsPanel = true
        let stage: NSSize
        /// Where the panel's card goes on the stage: its top-left corner, from the stage's top-left corner.
        let card: NSPoint
    }

    // Each stage has the aspect ratio of the image it's for: 1270×760 for Product Hunt, 1200×630 for og.png.
    // The panel is always where it opens on screen, so the card's top can't be more than ~200 points down a stage
    // without the stage reaching into the menu bar.
    private static let stills = [
        Still(name: "hero", query: "", stage: NSSize(width: 1100, height: 658), card: NSPoint(x: 210, y: 165)),
        Still(name: "tabs", query: "jira", stage: NSSize(width: 820, height: 491), card: NSPoint(x: 70, y: 178)),
        Still(name: "apps", query: "map", selectsLast: true, stage: NSSize(width: 820, height: 491), card: NSPoint(x: 70, y: 180)),
        Still(name: "og", query: "", stage: NSSize(width: 1000, height: 525), card: NSPoint(x: 400, y: 112)),
        Still(name: "plain", query: "", showsPanel: false, stage: NSSize(width: 1100, height: 658), card: NSPoint(x: 210, y: 165)),
    ]

    private static var app: AppDelegate!
    private static var screen: NSScreen!
    private static var backdrop: NSWindow!
    private static var desktop: DesktopView!
    private static var world = World()

    private static var model: SwitcherModel { app.switcherModel }

    static func run(app delegate: AppDelegate) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        app = delegate
        screen = NSScreen.screens[0]

        // Return switches on the sample desktop, never to a real window, tab or app.
        model.onConfirm = { item in bringForward(item.id) }
        model.onSwitchToTab = { tab, _ in
            world.activeTab = tab.index
            bringForward(World.safariWindowID)
        }
        model.onOpen = { installed in
            app.hide()
            world.launch(installed.path)
            desktop.showFront(world.windows[0], of: world, animated: true)
        }

        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--stills"), arguments.indices.contains(flag + 1) {
            makeBackdrop(frame: stageFrame(size: stills[0].stage, card: stills[0].card))
            Task { await poseStills(into: URL(fileURLWithPath: arguments[flag + 1])) }
        } else {
            let stage = stageFrame(size: stageSize, card: NSPoint(x: (stageSize.width - Layout.width) / 2, y: captionBand))
            makeBackdrop(frame: stage)
            report("RECT \(captureRect(of: stage))")
            Task { await play() }
        }
    }

    // MARK: Video

    private static func play() async {
        let pointer = parkPointer()
        desktop.showFront(world.windows[0], of: world, animated: false)
        await pause(3) // gives record.sh time to start the recorder
        report("SHOW \(Date().timeIntervalSince1970)")

        await caption("Any window, a few letters away")
        await openPanel()
        await pause(0.9)
        await type("rdmp")
        await pause(1.1)
        await pressReturn()
        await pause(0.8)

        await caption("Browser tabs too, even by their address")
        await openPanel()
        await pause(0.6)
        await type("jira")
        await pause(1.5)
        await pressReturn()
        await pause(0.8)

        await caption("And apps that aren't running yet")
        await openPanel()
        await pause(0.6)
        await type("calc")
        await pause(1.2)
        await pressReturn()
        await pause(0.9)

        await caption("⌘Space ↩ flips back to your last window")
        for flip in 0..<2 {
            await openPanel()
            await pause(0.9)
            await pressReturn()
            await pause(flip == 0 ? 0.8 : 1.1)
        }
        report("DONE \(Date().timeIntervalSince1970)")
        await pause(6) // past the end of the recording
        if let pointer { CGWarpMouseCursorPosition(pointer) }
        NSApp.terminate(nil)
    }

    private static func caption(_ text: String) async {
        desktop.setCaption(text)
        await pause(0.45)
    }

    /// ⌘Space: the panel lists the sample desktop's windows, Safari's tabs in place of its window.
    private static func openPanel() async {
        desktop.press(["⌘", "Space"])
        await pause(0.12)
        app.show(on: screen, items: world.windowItems())
        let apps = world.notRunning.map { sample in
            let installed = InstalledApp(url: URL(fileURLWithPath: sample.path), path: sample.path, name: sample.name,
                                         searchText: Array(sample.name))
            InstalledApps.setIcon(icon(of: sample.path), for: installed)
            return installed
        }
        model.apps = apps
        model.setTabs(world.tabs(), of: World.safari.pid)
    }

    private static func pressReturn() async {
        desktop.press(["↩"])
        await pause(0.12)
        press(#selector(NSResponder.insertNewline(_:)))
    }

    private static func bringForward(_ windowID: String) {
        app.hide()
        world.bringForward(windowID)
        desktop.showFront(world.windows[0], of: world, animated: true)
    }

    // MARK: Stills

    private struct StillInfo: Codable {
        let name: String
        let stage: CGSize
        /// The panel's card on the stage, from its top-left corner, in points.
        let card: CGRect?
    }

    private static func poseStills(into folder: URL) async {
        let pointer = parkPointer()
        desktop.showsWindows = false
        desktop.showsKeys = false
        var infos: [StillInfo] = []
        for still in stills {
            world = World()
            let stage = stageFrame(size: still.stage, card: still.card)
            backdrop.setFrame(stage, display: true)
            desktop.glowCenter = NSPoint(x: still.card.x + Layout.width / 2, y: still.card.y + 200)
            var card: CGRect?
            if still.showsPanel {
                await openPanel()
                if !still.query.isEmpty { searchEditor?.insertText(still.query, replacementRange: NSRange(location: NSNotFound, length: 0)) }
                if still.selectsLast { press(#selector(NSResponder.moveUp(_:))) }
                card = CGRect(x: still.card.x, y: still.card.y, width: Layout.width, height: model.height)
            }
            await pause(1) // the glass settles

            let file = folder.appendingPathComponent(still.name + ".png")
            report("STILL \(still.name) \(captureRect(of: stage))")
            let deadline = Date().addingTimeInterval(15)
            while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
                await pause(0.1)
            }
            infos.append(StillInfo(name: still.name, stage: still.stage, card: card))
            app.hide()
            await pause(0.3)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(infos).write(to: folder.appendingPathComponent("manifest.json"))
        report("DONE \(Date().timeIntervalSince1970)")
        if let pointer { CGWarpMouseCursorPosition(pointer) }
        NSApp.terminate(nil)
    }

    // MARK: Input

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

    /// Moves the pointer to the bottom-right corner, outside anything recorded. Returns where it was.
    private static func parkPointer() -> CGPoint? {
        let pointer = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(CGPoint(x: screen.frame.maxX - 2, y: screen.frame.maxY - 2))
        return pointer
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func report(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    // MARK: Stage

    /// A stage of `size`, placed so that the panel's card, which opens where it always does, lands at `card`.
    private static func stageFrame(size: NSSize, card: NSPoint) -> NSRect {
        let panelX = screen.visibleFrame.midX - Layout.width / 2 // as AppDelegate.show(on:) places it
        let frame = NSRect(x: (panelX - card.x).rounded(), y: (Layout.cardTop(on: screen) + card.y - size.height).rounded(),
                           width: size.width, height: size.height)
        if !screen.visibleFrame.contains(frame) {
            FileHandle.standardError.write(Data("Stage \(frame) doesn't fit on the screen \(screen.visibleFrame)\n".utf8))
        }
        return frame
    }

    /// `frame` as screencapture -R takes it: points from the main display's top-left corner.
    private static func captureRect(of frame: NSRect) -> String {
        let top = screen.frame.maxY - frame.maxY
        return "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))"
    }

    private static func makeBackdrop(frame: NSRect) {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        desktop = DesktopView(frame: NSRect(origin: .zero, size: frame.size))
        desktop.autoresizingMask = [.width, .height]
        window.contentView = desktop
        window.orderFrontRegardless()
        backdrop = window
    }

    private static var icons: [String: NSImage] = [:]

    /// The app's own icon file, so the recording shows full-colour icons whatever the system icon style.
    static func icon(of appPath: String) -> NSImage {
        if let icon = icons[appPath] { return icon }
        let bundle = Bundle(path: appPath)
        var icon = NSWorkspace.shared.icon(forFile: appPath)
        if let name = bundle?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let url = bundle?.url(forResource: (name as NSString).deletingPathExtension, withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            icon = image
        }
        icons[appPath] = icon
        return icon
    }
}

// MARK: Sample desktop

/// The made-up desktop: its windows front to back, Safari's tabs, and installed apps that aren't running.
@MainActor
private struct World {
    struct App {
        let name: String
        let path: String
        let pid: pid_t // made up; nothing is ever sent to it
    }

    enum Look { case terminal, notes, safari, calculator, plain }

    struct Window {
        let id: String
        let app: App
        let title: String
        var isMinimized = false
        let look: Look
    }

    static let terminal = App(name: "Terminal", path: "/System/Applications/Utilities/Terminal.app", pid: 90_001)
    static let notes = App(name: "Notes", path: "/System/Applications/Notes.app", pid: 90_002)
    static let safari = App(name: "Safari", path: "/Applications/Safari.app", pid: 90_003)
    static let safariWindowID = "demo-safari"

    var windows = [
        Window(id: "demo-terminal", app: terminal, title: "lightswitch — zsh — 120×40", look: .terminal),
        Window(id: "demo-roadmap", app: notes, title: "Q4 roadmap", look: .notes),
        Window(id: safariWindowID, app: safari, title: "", look: .safari),
        Window(id: "demo-mail", app: App(name: "Mail", path: "/System/Applications/Mail.app", pid: 90_004),
               title: "Inbox — 3 unread", look: .plain),
        Window(id: "demo-preview", app: App(name: "Preview", path: "/System/Applications/Preview.app", pid: 90_005),
               title: "design-review.pdf", look: .plain),
        Window(id: "demo-calendar", app: App(name: "Calendar", path: "/System/Applications/Calendar.app", pid: 90_006),
               title: "Team offsite — October", look: .plain),
        Window(id: "demo-finder", app: App(name: "Finder", path: "/System/Library/CoreServices/Finder.app", pid: 90_007),
               title: "Downloads", look: .plain),
        Window(id: "demo-sync", app: notes, title: "Weekly sync notes", isMinimized: true, look: .notes),
    ]
    let safariTabs: [(title: String, url: String)] = [
        ("Pull requests · aftab404/lightswitch", "https://github.com/aftab404/lightswitch/pulls"),
        ("Sprint board - Agile board", "https://jira.acme.com/software/projects/WEB/boards/4"),
        ("LS-142 Flip back to the previous window", "https://jira.acme.com/browse/LS-142"),
        ("Coffee near me - Google Maps", "https://www.google.com/maps/search/coffee"),
    ]
    var activeTab = 1
    var notRunning = [
        App(name: "Calculator", path: "/System/Applications/Calculator.app", pid: 90_008),
        App(name: "Maps", path: "/System/Applications/Maps.app", pid: 90_009),
    ]

    func title(of window: Window) -> String {
        window.look == .safari ? safariTabs[activeTab - 1].title : window.title
    }

    /// The rows the window list would have: front to back, minimized windows last. The window you were in before
    /// this one is second.
    func windowItems() -> [WindowItem] {
        // Any element will do: sample rows are never focused, and nil would mark them as app-only rows.
        let placeholder = AXUIElementCreateApplication(getpid())
        let ordered = windows.filter { !$0.isMinimized } + windows.filter(\.isMinimized)
        return ordered.enumerated().map { index, window in
            var item = WindowItem(id: window.id, pid: window.app.pid, appName: window.app.name, title: title(of: window),
                                  element: placeholder, isMinimized: window.isMinimized, isAppHidden: false,
                                  icon: Demo.icon(of: window.app.path))
            item.isPrevious = index == 1
            return item
        }
    }

    func tabs() -> [BrowserTab] {
        BrowserTab.samples(pid: Self.safari.pid, browserName: Self.safari.name, icon: Demo.icon(of: Self.safari.path),
                           windowOrder: 1, tabs: safariTabs, active: activeTab)
    }

    mutating func bringForward(_ id: String) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        windows.insert(windows.remove(at: index), at: 0)
    }

    mutating func launch(_ path: String) {
        guard let index = notRunning.firstIndex(where: { $0.path == path }) else { return }
        let app = notRunning.remove(at: index)
        windows.insert(Window(id: "demo-\(app.name)", app: app, title: app.name,
                              look: app.name == "Calculator" ? .calculator : .plain), at: 0)
    }
}

// MARK: Views

private func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A dusky desktop with a warm glow: a few faint windows in the background, the window you're in, a caption above
/// where the panel opens and the keys being pressed below it.
private final class DesktopView: NSView {
    var showsWindows = true {
        didSet { needsDisplay = true }
    }
    var showsKeys = true
    /// The glow's centre, from the top-left corner. The middle, if nil.
    var glowCenter: NSPoint? {
        didSet { needsDisplay = true }
    }
    private var front: NSView?
    private let caption = NSTextField(labelWithString: "")
    private var keys: [NSView] = []
    private var keyPresses = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        caption.font = .systemFont(ofSize: 25, weight: .semibold)
        caption.textColor = .white
        caption.alignment = .center
        caption.alphaValue = 0
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 10
        caption.shadow = shadow
        addSubview(caption)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        caption.frame = NSRect(x: 16, y: bounds.height - 60, width: bounds.width - 32, height: 34)
    }

    func setCaption(_ text: String) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            caption.animator().alphaValue = 0
        }, completionHandler: { [caption] in
            caption.stringValue = text
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                caption.animator().alphaValue = 1
            }
        })
    }

    /// Shows keycaps below the panel for a moment, like a keystroke overlay.
    func press(_ labels: [String]) {
        guard showsKeys else { return }
        keys.forEach { $0.removeFromSuperview() }
        keyPresses += 1
        let press = keyPresses
        keys = labels.map { KeycapView(label: $0) }
        let spacing: CGFloat = 8
        let width = keys.reduce(-spacing) { $0 + $1.frame.width + spacing }
        var x = ((bounds.width - width) / 2).rounded()
        for key in keys {
            key.setFrameOrigin(NSPoint(x: x, y: 20))
            key.alphaValue = 0
            addSubview(key)
            x += key.frame.width + spacing
        }
        let shown = keys
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            shown.forEach { $0.animator().alphaValue = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.keyPresses == press else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                shown.forEach { $0.animator().alphaValue = 0 }
            }
        }
    }

    /// The host, as Safari's address field shows it.
    private func domain(of url: String) -> String {
        let host = URL(string: url)?.host() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Puts `window` in front: the window you're in now.
    func showFront(_ window: World.Window, of world: World, animated: Bool) {
        let icon = Demo.icon(of: window.app.path)
        let title = world.title(of: window)
        let size = window.look == .calculator ? NSSize(width: 251, height: 422) : NSSize(width: 600, height: 410)
        let top: CGFloat = 104
        let frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.height - top - size.height,
                           width: size.width, height: size.height)
        let look: FauxWindowView.Content = switch window.look {
        case .terminal: .terminal
        case .notes: .notes(title: title, lines: ["Search browser tabs", "Open apps that aren't running",
                                                  "⌘Space ↩ flips back", "Ship 1.1"])
        case .safari: .safari(tabs: world.safariTabs.map(\.title), active: world.activeTab - 1,
                              address: domain(of: world.safariTabs[world.activeTab - 1].url))
        case .calculator: .calculator
        case .plain: .plain
        }
        let view = FauxWindowView(frame: frame, icon: icon, title: title, content: look)
        addSubview(view, positioned: .below, relativeTo: caption)
        let old = front
        front = view
        guard animated else {
            old?.removeFromSuperview()
            return
        }
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            view.animator().alphaValue = 1
            old?.animator().alphaValue = 0
        }, completionHandler: {
            old?.removeFromSuperview()
        })
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [color(0x2C2B5E), color(0x1A1C41), color(0x3A2350), color(0x0E0F22)],
                   atLocations: [0, 0.45, 0.75, 1], colorSpace: .sRGB)!
            .draw(in: bounds, angle: -40)
        let glow = glowCenter.map { NSPoint(x: $0.x, y: bounds.height - $0.y) } ?? NSPoint(x: bounds.midX, y: bounds.midY + 40)
        NSGradient(starting: color(0xFFAA46, 0.32), ending: color(0xFFAA46, 0))!
            .draw(fromCenter: glow, radius: 0, toCenter: glow, radius: max(bounds.width, 760) * 0.45, options: [])
        guard showsWindows else { return }

        let windows = [
            NSRect(x: bounds.width * 0.02, y: bounds.height * 0.32, width: bounds.width * 0.4, height: bounds.height * 0.55),
            NSRect(x: bounds.width * 0.6, y: bounds.height * 0.08, width: bounds.width * 0.38, height: bounds.height * 0.62),
            NSRect(x: bounds.width * 0.26, y: -bounds.height * 0.12, width: bounds.width * 0.46, height: bounds.height * 0.3),
        ]
        for rect in windows {
            let shape = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
            NSColor.white.withAlphaComponent(0.07).setFill()
            shape.fill()
            NSColor.white.withAlphaComponent(0.13).setStroke()
            shape.stroke()
            for index in 0..<3 {
                NSColor.white.withAlphaComponent(0.3).setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.minX + 16 + CGFloat(index) * 18, y: rect.maxY - 24, width: 10, height: 10)).fill()
            }
            NSColor.white.withAlphaComponent(0.08).setFill()
            for line in 0..<4 {
                let width = rect.width * [0.7, 0.5, 0.62, 0.4][line]
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 18, y: rect.maxY - 62 - CGFloat(line) * 30, width: width, height: 12),
                             xRadius: 6, yRadius: 6).fill()
            }
        }
    }
}

/// A key being pressed, in the site's amber.
private final class KeycapView: NSView {
    private let label: NSAttributedString

    init(label text: String) {
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
            .foregroundColor: color(0x2A1800),
        ])
        self.label = label
        let width = max(46, (label.size().width + 30).rounded())
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 42))
        wantsLayer = true
        let glow = NSShadow()
        glow.shadowColor = color(0xFFA62E, 0.55)
        glow.shadowBlurRadius = 16
        shadow = glow
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let key = bounds.insetBy(dx: 1, dy: 1)
        color(0xC9801C).setFill()
        NSBezierPath(roundedRect: key, xRadius: 9, yRadius: 9).fill()
        NSGradient(starting: color(0xFFC766), ending: color(0xFFAE3D))!
            .draw(in: NSBezierPath(roundedRect: NSRect(x: key.minX, y: key.minY + 3, width: key.width, height: key.height - 3),
                                   xRadius: 9, yRadius: 9), angle: -90)
        let size = label.size()
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2 + 1.5))
    }
}

/// A stand-in for an app's window, enough to tell which one you're in.
private final class FauxWindowView: NSView {
    enum Content {
        case terminal
        case notes(title: String, lines: [String])
        case safari(tabs: [String], active: Int, address: String)
        case calculator
        case plain
    }

    private let icon: NSImage
    private let title: String
    private let content: Content
    private static let titleBarHeight: CGFloat = 40

    init(frame: NSRect, icon: NSImage, title: String, content: Content) {
        self.icon = icon
        self.title = title
        self.content = content
        super.init(frame: frame)
        wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        self.shadow = shadow
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        if case .terminal = content { color(0x121216).setFill() } else { color(0x1E1E25).setFill() }
        body.fill()

        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        color(0x2A2A33).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.titleBarHeight).fill()
        for (index, light) in [color(0xFF5F57), color(0xFEBC2E), color(0x28C840)].enumerated() {
            light.setFill()
            NSBezierPath(ovalIn: NSRect(x: 16 + CGFloat(index) * 20, y: 14, width: 12, height: 12)).fill()
        }
        let titleText = text(title, size: 14, weight: .semibold, color: NSColor.white.withAlphaComponent(0.88))
        let titleWidth = min(titleText.size().width, bounds.width - 2 * 70 - 28) // clear of the traffic lights
        let titleX = ((bounds.width - titleWidth - 26) / 2).rounded()
        icon.draw(in: NSRect(x: titleX, y: 9, width: 22, height: 22))
        titleText.draw(with: NSRect(x: titleX + 28, y: 11, width: titleWidth, height: 20),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        switch content {
        case .terminal: drawTerminal()
        case .notes(let title, let lines): drawNotes(title: title, lines: lines)
        case .safari(let tabs, let active, let address): drawSafari(tabs: tabs, active: active, address: address)
        case .calculator: drawCalculator()
        case .plain: drawLines(from: Self.titleBarHeight + 30)
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.14).setStroke()
        body.stroke()
    }

    private func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                      monospaced: Bool = false) -> NSAttributedString {
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    private func drawTerminal() {
        let prompt = color(0x6BE38B), plain = NSColor.white.withAlphaComponent(0.88), dim = NSColor.white.withAlphaComponent(0.55)
        let lines: [[(String, NSColor)]] = [
            [("~/lightswitch", prompt), (" % ./build.sh demo", plain)],
            [("Built build/Lightswitch-demo.app (arm64)", dim)],
            [("~/lightswitch", prompt), (" % ", plain)],
        ]
        var end = NSPoint.zero
        for (index, line) in lines.enumerated() {
            let output = NSMutableAttributedString()
            for (piece, pieceColor) in line { output.append(text(piece, size: 14, color: pieceColor, monospaced: true)) }
            end = NSPoint(x: 20 + output.size().width, y: Self.titleBarHeight + 18 + CGFloat(index) * 24)
            output.draw(at: NSPoint(x: 20, y: end.y))
        }
        NSColor.white.withAlphaComponent(0.8).setFill()
        NSRect(x: end.x + 1, y: end.y + 1, width: 9, height: 17).fill()
    }

    private func drawNotes(title: String, lines: [String]) {
        text(title, size: 26, weight: .bold, color: .white).draw(at: NSPoint(x: 32, y: Self.titleBarHeight + 26))
        for (index, line) in lines.enumerated() {
            let y = Self.titleBarHeight + 84 + CGFloat(index) * 34
            color(0xF5C400).setFill()
            NSBezierPath(ovalIn: NSRect(x: 34, y: y + 7, width: 7, height: 7)).fill()
            text(line, size: 17, color: NSColor.white.withAlphaComponent(0.86)).draw(at: NSPoint(x: 52, y: y))
        }
    }

    private func drawSafari(tabs: [String], active: Int, address: String) {
        let barTop = Self.titleBarHeight
        color(0x2A2A33).setFill()
        NSRect(x: 0, y: barTop, width: bounds.width, height: 76).fill()
        let field = NSRect(x: (bounds.width - 300) / 2, y: barTop + 6, width: 300, height: 28)
        NSColor.white.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: field, xRadius: 9, yRadius: 9).fill()
        let host = text(address, size: 13, weight: .medium, color: NSColor.white.withAlphaComponent(0.8))
        host.draw(at: NSPoint(x: field.midX - host.size().width / 2, y: field.minY + 6))

        let tabWidth = (bounds.width - 24) / CGFloat(tabs.count)
        for (index, tab) in tabs.enumerated() {
            let rect = NSRect(x: 12 + CGFloat(index) * tabWidth + 2, y: barTop + 42, width: tabWidth - 4, height: 26)
            NSColor.white.withAlphaComponent(index == active ? 0.16 : 0.04).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            text(tab, size: 11, weight: index == active ? .semibold : .regular,
                 color: NSColor.white.withAlphaComponent(index == active ? 0.92 : 0.5))
                .draw(with: NSRect(x: rect.minX + 10, y: rect.minY + 6, width: rect.width - 20, height: 15),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        let pageTop = barTop + 76
        text(tabs[active], size: 20, weight: .bold, color: .white).draw(with: NSRect(x: 28, y: pageTop + 22, width: bounds.width - 56, height: 26),
                                                                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let columnWidth = (bounds.width - 56 - 24) / 3
        for column in 0..<3 {
            let x = 28 + CGFloat(column) * (columnWidth + 12)
            NSColor.white.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: pageTop + 64, width: columnWidth, height: bounds.height - pageTop - 84),
                         xRadius: 10, yRadius: 10).fill()
            for card in 0..<(3 - column % 2) {
                let rect = NSRect(x: x + 10, y: pageTop + 76 + CGFloat(card) * 62, width: columnWidth - 20, height: 52)
                NSColor.white.withAlphaComponent(0.09).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
                NSColor.white.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 10, y: rect.minY + 12, width: rect.width * 0.7, height: 8),
                             xRadius: 4, yRadius: 4).fill()
                color(0x4C8DFF, 0.7).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 10, y: rect.minY + 30, width: 34, height: 8), xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    private func drawCalculator() {
        let display = text("0", size: 56, weight: .light, color: .white)
        display.draw(at: NSPoint(x: bounds.width - 22 - display.size().width, y: Self.titleBarHeight + 10))
        let rows = [["⌫", "AC", "%", "÷"], ["7", "8", "9", "×"], ["4", "5", "6", "−"], ["1", "2", "3", "+"], ["+/−", "0", ".", "="]]
        let diameter: CGFloat = 48, gap: CGFloat = 9
        for (row, keys) in rows.enumerated() {
            for (column, key) in keys.enumerated() {
                let rect = NSRect(x: 16 + CGFloat(column) * (diameter + gap),
                                  y: Self.titleBarHeight + 90 + CGFloat(row) * (diameter + gap), width: diameter, height: diameter)
                (column == 3 ? color(0xFF9F0A) : row == 0 ? color(0x5B5B5F) : color(0x333338)).setFill()
                NSBezierPath(ovalIn: rect).fill()
                let label = text(key, size: key.count > 2 ? 15 : 20, weight: .medium, color: .white)
                let size = label.size()
                label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            }
        }
    }

    private func drawLines(from top: CGFloat) {
        NSColor.white.withAlphaComponent(0.1).setFill()
        for line in 0..<6 {
            let width = (bounds.width - 64) * [0.8, 0.55, 0.7, 0.45, 0.62, 0.5][line]
            NSBezierPath(roundedRect: NSRect(x: 32, y: top + CGFloat(line) * 34, width: width, height: 12), xRadius: 6, yRadius: 6).fill()
        }
    }
}
