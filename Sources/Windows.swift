import AppKit
import ApplicationServices

// Private but long-stable HIServices call that maps an AX window to its CGWindowID,
// which lets us order windows by their real on-screen stacking order.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

/// Looks up a private function at runtime, so a macOS without it falls back instead of failing to launch.
private func privateFunction<T>(_ name: String, as type: T.Type) -> T? {
    // RTLD_DEFAULT: everything loaded already, which includes CoreServices and CoreGraphics.
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
}

/// Launch Services' order of apps, most recently active first, which is the order ⌘Tab shows. Unlike activation
/// notifications it covers the time before Lightswitch launched, and it follows the user across Spaces.
private enum LaunchServicesOrder {
    private typealias CopyApps = @convention(c) (Int32, UInt32) -> Unmanaged<CFArray>?
    private typealias CopyInformationItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private static let session: Int32 = -2 // kLSDefaultSessionID
    private static let copyApps = privateFunction("_LSCopyApplicationArrayInFrontToBackOrder", as: CopyApps.self)
    private static let copyInformationItem = privateFunction("_LSCopyApplicationInformationItem", as: CopyInformationItem.self)
    private static let pidKey = privateFunction("_kLSPIDKey", as: UnsafePointer<CFString>.self)?.pointee

    /// nil if Launch Services won't say.
    static func pids() -> [pid_t]? {
        guard let copyApps, let copyInformationItem, let pidKey,
              let apps = copyApps(session, 0)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let pids = apps.compactMap {
            (copyInformationItem(session, $0, pidKey)?.takeRetainedValue() as? NSNumber)?.int32Value
        }
        return pids.isEmpty ? nil : pids
    }
}

/// Whether the window server has a window ordered in. Minimized windows aren't, and neither are the closed ones apps
/// keep around. A window that is ordered in but not on screen is on a Space that isn't showing, or in full screen.
private enum OrderedIn {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias WindowIsOrderedIn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Bool>) -> CGError
    private static let connection = privateFunction("CGSMainConnectionID", as: MainConnectionID.self)?()
    private static let windowIsOrderedIn = privateFunction("CGSWindowIsOrderedIn", as: WindowIsOrderedIn.self)

    /// Whether any of `windows` is, or nil if the window server won't say.
    static func any(_ windows: [CGWindowID]) -> Bool? {
        guard let connection, let windowIsOrderedIn else { return nil }
        return windows.contains { window in
            var isOrderedIn = false
            return windowIsOrderedIn(connection, window, &isOrderedIn) == .success && isOrderedIn
        }
    }
}

enum Accessibility {
    /// Nothing asks other apps anything over Accessibility until this is true: an app that turned down a request from
    /// Lightswitch keeps refusing it after access is granted, until Lightswitch restarts.
    static var isTrusted: Bool {
        #if DEMO
        return true // demo recordings use sample windows and never touch other apps
        #else
        return AXIsProcessTrusted()
        #endif
    }

    /// Shows the system prompt if access hasn't been granted yet.
    static func requestIfNeeded() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// After an update, macOS keeps the old build's entry in the Accessibility list, still switched on but
    /// no longer matching this build, and won't prompt again. Clearing our own entry makes it ask afresh.
    static func requestAgain() {
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.aftabkhan.lightswitch"]
        do {
            try reset.run()
            reset.waitUntilExit()
        } catch {
            NSLog("Lightswitch: could not reset the Accessibility entry: \(error)")
        }
        requestIfNeeded()
    }
}

struct WindowItem: Identifiable {
    let id: String
    let pid: pid_t
    let appName: String
    let title: String
    /// nil for a row that stands for the app itself, when we can't reach a window of it to show (e.g. it has none, or
    /// they're on another Space and its main window can't be reached).
    let element: AXUIElement?
    let isMinimized: Bool
    let isAppHidden: Bool
    var icon: NSImage?
    /// 0 for a row that stands for the app.
    var windowID: CGWindowID = 0
    /// The window you were in before the one you're in now, which the switcher preselects.
    var isPrevious = false

    var displayTitle: String { title.isEmpty ? appName : title }

    var badge: String? {
        if element == nil { return "App" }
        if isMinimized { return "Minimized" }
        if isAppHidden { return "Hidden" }
        return nil
    }
}

enum WindowList {
    private static var recentPIDs: [pid_t] = []

    /// Follows which app, and which of its windows, you're in. Main thread only.
    static func startTrackingRecency() {
        if let front = NSWorkspace.shared.frontmostApplication {
            recentPIDs = [front.processIdentifier]
            watchWindows(of: front)
            recordVisitSoon()
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            recentPIDs.removeAll { $0 == app.processIdentifier }
            recentPIDs.insert(app.processIdentifier, at: 0)
            watchWindows(of: app)
            recordVisitSoon()
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            stopWatchingWindows(of: app.processIdentifier)
        }
    }

    private struct AppInfo {
        let pid: pid_t
        let name: String
        let isHidden: Bool
        /// 0 for the app used last.
        let recency: Int
    }

    /// Collects every window of every regular app, front-most first. Calls back on the main thread.
    static func fetch(completion: @escaping @MainActor ([WindowItem]) -> Void) {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isTerminated
        }
        let recent = LaunchServicesOrder.pids() ?? recentPIDs
        let apps = running.enumerated().map { index, app in
            AppInfo(
                pid: app.processIdentifier,
                name: app.localizedName ?? "Unknown",
                isHidden: app.isHidden,
                recency: recent.firstIndex(of: app.processIdentifier) ?? (recent.count + index)
            )
        }
        let icons = Dictionary(running.map { ($0.processIdentifier, $0.icon) }, uniquingKeysWith: { a, _ in a })
        // The panel never activates Lightswitch, so the frontmost app is still the one you're in.
        let frontmost = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == getpid() ? nil : $0 }
        if let frontmost { watchWindows(of: frontmost) } // in case that failed when it was activated
        let visited = visits
        let isTrusted = Accessibility.isTrusted

        DispatchQueue.global(qos: .userInteractive).async {
            let stacking = onScreenStackingOrder()
            var perApp = [[WindowItem]](repeating: [], count: apps.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: isTrusted ? apps.count : 0) { i in
                let found = windows(of: apps[i])
                lock.lock()
                perApp[i] = found
                lock.unlock()
            }
            var items = arrange(perApp, of: apps, stacking: stacking)
            let current = isTrusted ? frontmost.flatMap { windowYoureIn(of: $0.processIdentifier) } : nil
            markPrevious(in: &items, current: current?.windowID, visited: visited, apps: apps)

            DispatchQueue.main.async {
                if let current { remember(current) }
                completion(items.map { item in
                    var item = item
                    item.icon = icons[item.pid] ?? nil
                    return item
                })
            }
        }
    }

    /// Windows on this desktop keep their stacking order. Everything else goes by how recently its app was used, so
    /// an app's window on another desktop or in full screen comes before the on-screen windows of apps used less
    /// recently, and before its own: it can only be its main window, the one used last. Minimized windows, hidden
    /// apps and apps without windows were put away and stay below all the on-screen windows.
    private static func arrange(_ perApp: [[WindowItem]], of apps: [AppInfo], stacking: [CGWindowID: Int]) -> [WindowItem] {
        let offScreen = offScreenWindows(notIn: stacking)
        var onScreen: [(z: Int, recency: Int, item: WindowItem)] = []
        // Keyed by app recency, then the app's own row before its windows.
        var elsewhere: [(key: (Int, Int), item: WindowItem)] = []
        var putAway: [(key: (Int, Int), item: WindowItem)] = []

        for (appIndex, app) in apps.enumerated() {
            let found = perApp[appIndex]
            var hasWindowToShow = false
            for (windowIndex, window) in found.enumerated() {
                let key = (app.recency, 1 + windowIndex)
                if window.isMinimized || app.isHidden {
                    putAway.append((key, window))
                } else if let z = stacking[window.windowID] {
                    onScreen.append((z, app.recency, window))
                    hasWindowToShow = true
                } else {
                    elsewhere.append((key, window))
                    hasWindowToShow = true
                }
            }
            guard !hasWindowToShow else { continue }

            // A row for the app itself, which activating takes to a Space with its windows if it has some there that
            // Accessibility couldn't reach. An app with minimized windows only is listed by those. If the window
            // server won't say, an app without windows we could reach is taken to have some elsewhere.
            let isElsewhere = !app.isHidden && (OrderedIn.any(offScreen[app.pid] ?? []) ?? found.isEmpty)
            guard isElsewhere || found.isEmpty else { continue }
            let item = WindowItem(id: "app-\(app.pid)", pid: app.pid, appName: app.name, title: "",
                                  element: nil, isMinimized: false, isAppHidden: app.isHidden)
            if isElsewhere {
                elsewhere.append(((app.recency, 0), item))
            } else {
                putAway.append(((app.recency, 0), item))
            }
        }

        onScreen.sort { $0.z < $1.z }
        elsewhere.sort { $0.key < $1.key }
        var arranged: [WindowItem] = []
        var next = 0
        for window in onScreen {
            while next < elsewhere.count, elsewhere[next].key.0 <= window.recency {
                arranged.append(elsewhere[next].item)
                next += 1
            }
            arranged.append(window.item)
        }
        let rest = (elsewhere[next...] + putAway).sorted { $0.key < $1.key }
        return arranged + rest.map(\.item)
    }

    private static func onScreenStackingOrder() -> [CGWindowID: Int] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var order: [CGWindowID: Int] = [:]
        for (index, info) in list.enumerated() {
            if let id = info[kCGWindowNumber as String] as? CGWindowID { order[id] = index }
        }
        return order
    }

    /// Each app's normal-level windows that aren't on screen, from every Space, by pid.
    private static func offScreenWindows(notIn onScreen: [CGWindowID: Int]) -> [pid_t: [CGWindowID]] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var windows: [pid_t: [CGWindowID]] = [:]
        for info in list {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID, onScreen[id] == nil,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t
            else { continue }
            windows[pid, default: []].append(id)
        }
        return windows
    }

    private static func windows(of app: AppInfo) -> [WindowItem] {
        // Don't let a hung app stall the switcher. The timeout is per element, so every window gets one too.
        let axApp = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        guard var windows = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        // The list only has this Space's windows and minimized ones, but the main window, the one used last, can be
        // reached even when it's on another Space or in full screen.
        if let main = attribute(axApp, kAXMainWindowAttribute), CFGetTypeID(main) == AXUIElementGetTypeID() {
            windows.insert(main as! AXUIElement, at: 0)
        }

        var seen = Set<CGWindowID>()
        return windows.enumerated().compactMap { index, window in
            AXUIElementSetMessagingTimeout(window, 0.3)
            let subrole = attribute(window, kAXSubroleAttribute) as? String
            guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { return nil }
            var windowID: CGWindowID = 0
            _AXUIElementGetWindow(window, &windowID)
            guard windowID == 0 || seen.insert(windowID).inserted else { return nil } // the main window, listed again
            return row(for: window, windowID: windowID, id: "\(app.pid)-\(windowID)-\(index)", of: app)
        }
    }

    private static func row(for window: AXUIElement, windowID: CGWindowID, id: String, of app: AppInfo) -> WindowItem {
        WindowItem(
            id: id,
            pid: app.pid,
            appName: app.name,
            title: attribute(window, kAXTitleAttribute) as? String ?? "",
            element: window,
            isMinimized: attribute(window, kAXMinimizedAttribute) as? Bool ?? false,
            isAppHidden: app.isHidden,
            windowID: windowID
        )
    }

    /// The app's front window as a row `focus` can raise, or an app-only row if Accessibility can't see one.
    static func frontWindow(of pid: pid_t) -> WindowItem {
        let app = NSRunningApplication(processIdentifier: pid)
        let info = AppInfo(pid: pid, name: app?.localizedName ?? "Unknown", isHidden: app?.isHidden ?? false, recency: 0)
        return (Accessibility.isTrusted ? windows(of: info).first : nil)
            ?? WindowItem(id: "app-\(pid)", pid: pid, appName: info.name, title: "",
                          element: nil, isMinimized: false, isAppHidden: info.isHidden)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func focus(_ item: WindowItem) {
        let app = NSRunningApplication(processIdentifier: item.pid)
        if app?.isHidden == true { app?.unhide() }

        if let window = item.element {
            if item.isMinimized {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        // Our panel never activates Lightswitch, and macOS may ignore activation requests from an app that
        // isn't active. Accessibility can make the app frontmost directly; without it, go through Launch
        // Services, the same route as clicking the app in the Dock. An app's own row always goes that way too:
        // Launch Services sends a running app a reopen event, so one without windows, such as Chrome after its
        // last tab closed, opens a new window as it would from the Dock, instead of just becoming active.
        let madeFrontmost = Accessibility.isTrusted && AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(item.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue
        ) == .success
        if !madeFrontmost || item.element == nil, let url = app?.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        app?.activate()

        // Some apps reshuffle their windows on activation; raise once more after it settles.
        if let window = item.element {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }
    }
}

// MARK: The window you came from

extension WindowList {
    /// A window you were in.
    private struct Visit {
        let pid: pid_t
        let windowID: CGWindowID
        let element: AXUIElement
    }

    /// The windows you've been in, most recent first.
    private static var visits: [Visit] = []
    private static var observers: [pid_t: AXObserver] = [:]
    private static var pendingVisit: DispatchWorkItem?

    /// Hears when the app's focused or main window changes, so switching between its windows counts too.
    private static func watchWindows(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, pid != getpid(), app.activationPolicy == .regular, Accessibility.isTrusted else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, _ in WindowList.recordVisitSoon() }, &observer) == .success,
              let observer else { return }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        let added = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification].filter {
            AXObserverAddNotification(observer, axApp, $0 as CFString, nil) == .success
        }
        // Not while the app is still starting up. Activating it tries again.
        guard !added.isEmpty else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private static func stopWatchingWindows(of pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        visits.removeAll { $0.pid == pid }
    }

    /// Notes the window you're in once a switch has settled, so its in-between states don't count.
    private static func recordVisitSoon() {
        pendingVisit?.cancel()
        let work = DispatchWorkItem {
            guard Accessibility.isTrusted, let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
                  let visit = windowYoureIn(of: app.processIdentifier) else { return }
            remember(visit)
        }
        pendingVisit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private static func remember(_ visit: Visit) {
        visits.removeAll { $0.windowID == visit.windowID }
        visits.insert(visit, at: 0)
        if visits.count > 10 { visits.removeLast() }
    }

    /// The app's focused window, or its main window while a panel or the like has focus.
    private static func windowYoureIn(of pid: pid_t) -> Visit? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard let value = attribute(axApp, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let window = value as! AXUIElement
            AXUIElementSetMessagingTimeout(window, 0.3)
            let subrole = attribute(window, kAXSubroleAttribute) as? String
            guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
            var windowID: CGWindowID = 0
            _AXUIElementGetWindow(window, &windowID)
            if windowID != 0 { return Visit(pid: pid, windowID: windowID, element: window) }
        }
        return nil
    }

    /// Moves the last window you were in, other than `current`, to just below it and marks it to be preselected.
    /// Windows closed or put away since are passed over. One the list doesn't have, such as another window of the
    /// same app on another Space, is added: its element still reaches it.
    private static func markPrevious(in items: inout [WindowItem], current: CGWindowID?, visited: [Visit], apps: [AppInfo]) {
        for visit in visited where visit.windowID != current {
            let listed = items.firstIndex { $0.windowID == visit.windowID }
            guard var previous = listed.map({ items[$0] }) ?? unlistedRow(for: visit, apps: apps),
                  !previous.isMinimized, !previous.isAppHidden else { continue }
            if let listed { items.remove(at: listed) }
            previous.isPrevious = true
            let below = current.flatMap { id in items.firstIndex { $0.windowID == id } }.map { $0 + 1 } ?? 0
            items.insert(previous, at: below)
            return
        }
    }

    private static func unlistedRow(for visit: Visit, apps: [AppInfo]) -> WindowItem? {
        guard let app = apps.first(where: { $0.pid == visit.pid }) else { return nil } // quit since
        AXUIElementSetMessagingTimeout(visit.element, 0.3)
        // Closed since? Closing a window usually invalidates its element; it's never ordered in any more.
        guard attribute(visit.element, kAXRoleAttribute) != nil, OrderedIn.any([visit.windowID]) ?? true else { return nil }
        return row(for: visit.element, windowID: visit.windowID, id: "\(app.pid)-\(visit.windowID)-visited", of: app)
    }
}

// MARK: Closing windows

extension WindowList {
    enum CloseOutcome {
        case closed
        /// Its close button was pressed but the window stayed, for example behind a "Save changes?" sheet.
        case stillOpen
        /// It has no close button, or one that's turned off.
        case notClosable
    }

    /// Presses the window's close button, as clicking it would, then calls back on the main thread with what happened.
    /// A window that's still there shortly after is left for the user to deal with.
    static func close(_ item: WindowItem, completion: @escaping @MainActor (CloseOutcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var outcome = CloseOutcome.notClosable
            if let window = item.element, let value = attribute(window, kAXCloseButtonAttribute),
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                let button = value as! AXUIElement
                AXUIElementSetMessagingTimeout(button, 0.3)
                // An app that asks before closing with an alert of its own doesn't answer until the user has.
                let pressed = attribute(button, kAXEnabledAttribute) as? Bool != false
                    && [.success, .cannotComplete].contains(AXUIElementPerformAction(button, kAXPressAction as CFString))
                if pressed {
                    outcome = .stillOpen
                    let deadline = Date() + 0.5
                    repeat {
                        if !isOpen(window, id: item.windowID, pid: item.pid) {
                            outcome = .closed
                            break
                        }
                        usleep(50_000)
                    } while Date() < deadline
                }
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Whether a window is still open. Closing one usually invalidates its element; an app that keeps a closed window
    /// around takes it out of its list of windows and orders it out.
    private static func isOpen(_ window: AXUIElement, id: CGWindowID, pid: pid_t) -> Bool {
        var role: CFTypeRef?
        switch AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) {
        case .success: break
        case .invalidUIElement: return false
        default: return true // busy, perhaps asking the user something
        }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        if let windows = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement], windows.contains(where: { CFEqual($0, window) }) {
            return true
        }
        // The list only has this Space's windows and minimized ones.
        return id == 0 || OrderedIn.any([id]) != false
    }
}
