import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = SwitcherModel()
    private var panel: SwitcherPanel!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
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
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)) { [weak self] in self?.toggle() }
        WindowList.startTrackingRecency()
        setUpStatusItem()
        setUpLoginItemOnFirstLaunch()

        Accessibility.requestIfNeeded()
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

        model.prepareForShow()
        resize(to: model.height)
        panel.makeKeyAndOrderFront(nil)

        if let items {
            model.items = items
            return
        }
        WindowList.fetch { [weak self] items in
            guard let self, self.panel.isVisible else { return }
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

        accessibilityItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
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

    @objc private func openAccessibilitySettings() {
        Accessibility.openSettings()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Lightswitch: login item change failed: \(error)")
        }
    }

    // The point of the app is to own ⌘Space, so it starts at login unless turned off from the menu.
    private func setUpLoginItemOnFirstLaunch() {
        let key = "didSetUpLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
