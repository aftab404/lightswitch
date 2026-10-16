import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let loginItemOffKey = "launchAtLoginTurnedOff"
    private static let loginItemPathKey = "launchAtLoginPath"

    private let model = SwitcherModel()
    private var panel: SwitcherPanel!
    private var shortcut = Shortcut.saved
    private var hotKey: HotKey?
    private let recorder = ShortcutRecorder()
    private let welcome = WelcomeWindow()
    private var shortcutWatch: Timer?
    private var statusItem: NSStatusItem!
    private var showItem: NSMenuItem!
    private var shortcutItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    /// Browsers whose tabs are still being read for this opening, and the window list if it's waiting for them.
    private var tabReads: Set<pid_t> = []
    private var heldWindows: [WindowItem]?
    private var panelX: CGFloat = 0
    private var panelTop: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = SwitcherPanel(model: model)
        model.onConfirm = { [weak self] item in self?.confirm(item) }
        model.onSwitchToTab = { [weak self] tab, window in self?.switchTo(tab, window: window) }
        model.onOpen = { [weak self] app in self?.open(app) }
        model.onCancel = { [weak self] in self?.hide() }
        model.onHeightChange = { [weak self] height in self?.resize(to: height) }
        recorder.onRecord = { [weak self] shortcut in self?.use(shortcut) }

        #if DEMO
        // `./build.sh demo`: play a scripted session with sample windows for screen recordings.
        Demo.run(app: self)
        #else
        registerHotKey()
        WindowList.startTrackingRecency()
        InstalledApps.onUpdate = { [weak self] in
            // A rescan that finishes while the panel is open (opening it starts one when the list is stale).
            guard let self, self.panel.isVisible else { return }
            self.model.apps = InstalledApps.launchable
        }
        InstalledApps.refreshIfStale()
        BrowserTabs.onUpdate = { [weak self] pid, tabs in
            // Possibly from a read started by an earlier opening that took a while; it's still recent.
            guard let self, self.panel.isVisible else { return }
            if let tabs { self.model.setTabs(tabs, of: pid) }
            self.tabReads.remove(pid)
            if self.tabReads.isEmpty { self.showHeldWindows() }
        }
        // Not in demo recordings, whose sample rows stand in for windows of real apps.
        model.onCloseWindow = { [weak self] item in self?.close(item) }
        model.onCloseTab = { [weak self] tab in self?.close(tab) }
        model.onQuit = { pid in
            if NSRunningApplication(processIdentifier: pid)?.terminate() != true { NSSound.beep() }
        }
        // Quit with ⌘Q from the panel, or some other way while it's open. An app that asks about unsaved changes
        // first quits once the user has answered, if they let it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            else { return }
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.model.appQuit(pid)
            }
        }
        setUpStatusItem()
        syncLoginItem()
        setUpWelcome()

        // One window for Accessibility, the shortcut and browser tabs, rather than a prompt and an alert of their own.
        if welcome.isNeededAtLaunch { welcome.show() }
        checkShortcut()
        if CommandLine.arguments.contains("--show") { show() }
        #endif
    }

    // Launching the app again (Finder, `open`) shows the switcher, or brings back the welcome window if it's open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        welcome.isVisible ? welcome.show() : show()
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
        welcome.switcherDidOpen()

        if let items {
            model.items = items
            return
        }
        model.apps = InstalledApps.launchable
        InstalledApps.refreshIfStale()
        // The welcome window asks about each browser itself, so trying the shortcut from there doesn't bring up prompts.
        tabReads = BrowserTabs.refresh(askingPermission: !welcome.isVisible)
        heldWindows = nil
        let opening = model.showCount
        WindowList.fetch { [weak self] items in
            // A slower fetch from an earlier opening mustn't replace this one's list.
            guard let self, self.panel.isVisible, self.model.showCount == opening else { return }
            guard !self.tabReads.isEmpty else {
                self.model.items = items
                return
            }
            // Browsers usually answer before the window list is ready. If one hasn't, give it a moment, so the list
            // comes up with its windows already split into tabs instead of rearranging itself just after.
            self.heldWindows = items
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.model.showCount == opening else { return }
                self.showHeldWindows()
            }
        }
    }

    #if DEMO
    /// The demo adds sample tabs and apps to the sample windows it shows, and plays out Return itself.
    var switcherModel: SwitcherModel { model }
    #endif

    private func showHeldWindows() {
        guard let windows = heldWindows else { return }
        heldWindows = nil
        model.items = windows
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func confirm(_ item: WindowItem) {
        hide()
        WindowList.focus(item)
    }

    private func switchTo(_ tab: BrowserTab, window: WindowItem?) {
        hide()
        BrowserTabs.select(tab) {
            // Once the browser has put the tab's window in front of its others, so its front window is that one.
            WindowList.focus(window ?? WindowList.frontWindow(of: tab.pid))
        }
    }

    private func open(_ app: InstalledApp) {
        hide()
        InstalledApps.open(app)
    }

    // The panel stays open while windows and tabs close, so several can be closed in a row.

    private func close(_ item: WindowItem) {
        let opening = model.showCount
        WindowList.close(item) { [weak self] outcome in
            if outcome == .notClosable { NSSound.beep() }
            guard let self, self.panel.isVisible, self.model.showCount == opening else { return }
            guard outcome == .closed else {
                self.model.closeEnded(item.id)
                return
            }
            self.model.windowClosed(item)
            // A browser window's tabs went with it.
            if BrowserTabs.running.contains(where: { $0.pid == item.pid }) {
                BrowserTabs.refresh(askingPermission: false)
            }
        }
    }

    private func close(_ tab: BrowserTab) {
        let opening = model.showCount
        BrowserTabs.close(tab) { [weak self] tabs in
            if tabs == nil { NSSound.beep() }
            guard let self, self.panel.isVisible, self.model.showCount == opening else { return }
            guard let tabs else {
                self.model.closeEnded(tab.id)
                return
            }
            // Closing its last tab closes a window, and closing the one it shows changes its title.
            WindowList.fetch { [weak self] windows in
                guard let self, self.panel.isVisible, self.model.showCount == opening else { return }
                self.model.tabClosed(tab, leaving: tabs, windows: windows)
            }
        }
    }

    private func resize(to height: CGFloat) {
        panel.setCardFrame(NSRect(x: panelX, y: panelTop - height, width: Layout.width, height: height))
    }

    // MARK: Shortcut

    /// Registers `shortcut` with macOS. False if it refused.
    @discardableResult
    private func registerHotKey() -> Bool {
        hotKey = nil // unregister the old one first
        hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            // While recording, pressing the current shortcut just keeps it.
            guard let self, !self.recorder.isVisible else { return }
            self.toggle()
        }
        return hotKey != nil
    }

    /// macOS's own shortcuts beat ours, so if one of them has ours, say so and take it over once it's freed.
    private func checkShortcut() {
        guard shortcut.isTakenBySystem else { return }
        shortcutItem.title = "\(shortcut) Is Used by \(shortcut.systemOwner?.section ?? "a macOS Shortcut")…"
        shortcutItem.isHidden = false
        // The welcome window explains this itself; the alert is for later launches.
        if !welcome.isVisible { DispatchQueue.main.async { self.showShortcutAlert() } }

        shortcutWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, !self.shortcut.isTakenBySystem else { return }
                timer.invalidate()
                self.shortcutItem.isHidden = true
                self.registerHotKey()
            }
        }
    }

    @objc private func showShortcutAlert() {
        let owner = shortcut.systemOwner
        let fix = owner.map { "In Keyboard Shortcuts → \($0.section), turn off “\($0.name)” or give it another shortcut." }
            ?? "In Keyboard Shortcuts, turn off the one that uses \(shortcut) or give it another shortcut."
        let alert = NSAlert()
        alert.messageText = "\(shortcut) is still used by \(owner?.section ?? "a macOS shortcut")"
        alert.informativeText = "macOS gives its own shortcuts priority, so Lightswitch can't open with \(shortcut) yet. \(fix) "
            + "Lightswitch takes over \(shortcut) as soon as it's free, or you can give Lightswitch a different shortcut."
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "Change Shortcut…")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
        case .alertSecondButtonReturn:
            changeShortcut()
        default:
            break
        }
    }

    @objc private func changeShortcut() {
        recorder.show(current: shortcut)
    }

    /// Makes `new` the global shortcut, or says why it can't be.
    private func use(_ new: Shortcut) -> String? {
        if new.isTakenBySystem {
            let owner = new.systemOwner.map { "\($0.section) (“\($0.name)”)" } ?? "a macOS shortcut"
            return "\(new) is used by \(owner). Pick another, or turn that one off in Keyboard Shortcuts first."
        }
        let old = shortcut
        shortcut = new
        guard registerHotKey() else {
            shortcut = old
            registerHotKey()
            return "macOS wouldn't register \(new). Pick another."
        }
        new.save()
        shortcutWatch?.invalidate()
        shortcutItem.isHidden = true
        welcome.refresh()
        return nil
    }

    // MARK: Welcome

    private func setUpWelcome() {
        let model = welcome.model
        model.currentShortcut = { [weak self] in self?.shortcut ?? .standard }
        model.isShortcutRegistered = { [weak self] in self?.hotKey != nil }
        model.onUseShortcut = { [weak self] shortcut in self?.use(shortcut) }
        model.onChangeShortcut = { [weak self] in self?.changeShortcut() }
        model.loginItemState = { [weak self] in
            guard let self, self.isInstalledCopy else { return nil }
            return SMAppService.mainApp.status == .enabled
        }
        model.onSetOpensAtLogin = { [weak self] on in
            guard (SMAppService.mainApp.status == .enabled) != on else { return }
            self?.toggleLoginItem()
        }
    }

    @objc private func showWelcome() {
        welcome.show()
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "lightswitch.on", accessibilityDescription: "Lightswitch")

        let menu = NSMenu()
        menu.delegate = self
        showItem = NSMenuItem(title: "Show Switcher", action: #selector(show as () -> Void), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())

        shortcutItem = NSMenuItem(title: "", action: #selector(showShortcutAlert), keyEquivalent: "")
        shortcutItem.target = self
        shortcutItem.isHidden = true
        menu.addItem(shortcutItem)

        accessibilityItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(requestAccessibility), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let setupItem = NSMenuItem(title: "Setup…", action: #selector(showWelcome), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        let changeItem = NSMenuItem(title: "Change Shortcut…", action: #selector(changeShortcut), keyEquivalent: "")
        changeItem.target = self
        menu.addItem(changeItem)

        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lightswitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        showItem.keyEquivalent = shortcut.keyEquivalent
        showItem.keyEquivalentModifierMask = shortcut.modifierFlags
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

    /// The point of the app is to be one shortcut away, so it starts at login unless turned off from the menu.
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
