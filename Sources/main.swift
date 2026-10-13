import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let shortcut = (keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
    private static let loginItemOffKey = "launchAtLoginTurnedOff"
    private static let loginItemPathKey = "launchAtLoginPath"

    private let model = SwitcherModel()
    private var panel: SwitcherPanel!
    private var hotKey: HotKey?
    private var shortcutWatch: Timer?
    private var statusItem: NSStatusItem!
    private var shortcutItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var panelX: CGFloat = 0
    private var panelTop: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = SwitcherPanel(model: model)
        model.onConfirm = { [weak self] item in self?.confirm(item) }
        model.onCancel = { [weak self] in self?.hide() }
        model.onHeightChange = { [weak self] height in self?.resize(to: height) }

        #if DEMO
        // `./build.sh demo`: play a scripted session with sample windows for screen recordings.
        Demo.run(app: self)
        #else
        registerHotKey()
        WindowList.startTrackingRecency()
        setUpStatusItem()
        syncLoginItem()

        Accessibility.requestIfNeeded()
        checkShortcut()
        if CommandLine.arguments.contains("--show") { show() }
        #endif
    }

    // Launching the app again (Finder, `open`) shows the switcher.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return false
    }

    // MARK: Panel

    private func toggle() {
        panel.isVisible ? hide() : show()
    }

    @objc private func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        show(on: screen)
    }

    /// Shows the panel on `screen`, listing `items` if given, otherwise the windows open right now.
    func show(on screen: NSScreen, items: [WindowItem]? = nil) {
        guard !panel.isVisible else { return }
        panelX = screen.visibleFrame.midX - Layout.width / 2
        panelTop = Layout.cardTop(on: screen)

        // The panel never activates Lightswitch, so the frontmost app is still the one the user was in.
        model.prepareForShow(currentApp: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        resize(to: model.height)
        panel.focusSearchField()
        panel.makeKeyAndOrderFront(nil)

        if let items {
            model.items = items
            return
        }
        let opening = model.showCount
        WindowList.fetch { [weak self] items in
            // A slower fetch from an earlier opening mustn't replace this one's list.
            guard let self, self.panel.isVisible, self.model.showCount == opening else { return }
            self.model.items = items
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func confirm(_ item: WindowItem) {
        hide()
        WindowList.focus(item)
    }

    private func resize(to height: CGFloat) {
        panel.setCardFrame(NSRect(x: panelX, y: panelTop - height, width: Layout.width, height: height))
    }

    // MARK: Shortcut

    private func registerHotKey() {
        hotKey = nil // unregister the old one first
        hotKey = HotKey(keyCode: Self.shortcut.keyCode, modifiers: Self.shortcut.modifiers) { [weak self] in self?.toggle() }
    }

    /// macOS's own shortcuts beat ours, so if Spotlight still has ⌘Space, say so and take it over once it's freed.
    private func checkShortcut() {
        guard HotKey.isTakenBySystem(keyCode: Self.shortcut.keyCode, modifiers: Self.shortcut.modifiers) else { return }
        shortcutItem.isHidden = false
        DispatchQueue.main.async { self.showShortcutAlert() }

        shortcutWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, !HotKey.isTakenBySystem(keyCode: Self.shortcut.keyCode, modifiers: Self.shortcut.modifiers) else { return }
                timer.invalidate()
                self.shortcutItem.isHidden = true
                self.registerHotKey()
            }
        }
    }

    @objc private func showShortcutAlert() {
        let alert = NSAlert()
        alert.messageText = "⌘Space is still used by Spotlight"
        alert.informativeText = "macOS gives its own shortcuts priority, so Lightswitch can't open with ⌘Space yet. "
            + "In Keyboard Shortcuts → Spotlight, turn off “Show Spotlight search” or give it another shortcut. "
            + "Lightswitch takes over ⌘Space as soon as it's free."
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "lightswitch.on", accessibilityDescription: "Lightswitch")

        let menu = NSMenu()
        menu.delegate = self
        let showItem = NSMenuItem(title: "Show Switcher", action: #selector(show as () -> Void), keyEquivalent: " ")
        showItem.keyEquivalentModifierMask = .command
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())

        shortcutItem = NSMenuItem(title: "⌘Space Is Used by Spotlight…", action: #selector(showShortcutAlert), keyEquivalent: "")
        shortcutItem.target = self
        shortcutItem.isHidden = true
        menu.addItem(shortcutItem)

        accessibilityItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(requestAccessibility), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lightswitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        accessibilityItem.isHidden = Accessibility.isTrusted
    }

    @objc private func requestAccessibility() {
        Accessibility.requestAgain()
    }

    // MARK: Login item

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        let turnOn = service.status != .enabled
        UserDefaults.standard.set(!turnOn, forKey: Self.loginItemOffKey)
        do {
            if turnOn {
                try service.register()
                UserDefaults.standard.set(Bundle.main.bundlePath, forKey: Self.loginItemPathKey)
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("Lightswitch: login item change failed: \(error)")
        }
    }

    /// The point of the app is to own ⌘Space, so it starts at login unless turned off from the menu.
    /// Only an installed copy registers: one running from the disk image, Downloads or a translocated
    /// path would leave login pointing at a copy that's about to disappear. Runs on every launch, so
    /// moving the app re-points the login item.
    private func syncLoginItem() {
        let defaults = UserDefaults.standard
        guard isInstalledCopy, !defaults.bool(forKey: Self.loginItemOffKey) else { return }
        let service = SMAppService.mainApp
        let path = Bundle.main.bundlePath
        if service.status == .enabled {
            guard defaults.string(forKey: Self.loginItemPathKey) != path else { return }
            try? service.unregister() // registered from another copy
        }
        do {
            try service.register()
            defaults.set(path, forKey: Self.loginItemPathKey)
        } catch {
            NSLog("Lightswitch: could not register the login item: \(error)")
        }
    }

    private var isInstalledCopy: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications + "/")
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
