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

    static func startTrackingRecency() {
        if let front = NSWorkspace.shared.frontmostApplication {
            recentPIDs = [front.processIdentifier]
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            recentPIDs.removeAll { $0 == app.processIdentifier }
            recentPIDs.insert(app.processIdentifier, at: 0)
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

        DispatchQueue.global(qos: .userInteractive).async {
            let stacking = onScreenStackingOrder()
            var perApp = [[(item: WindowItem, windowID: CGWindowID)]](repeating: [], count: apps.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: apps.count) { i in
                let found = windows(of: apps[i])
                lock.lock()
                perApp[i] = found
                lock.unlock()
            }
            let items = arrange(perApp, of: apps, stacking: stacking)

            DispatchQueue.main.async {
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
    private static func arrange(_ perApp: [[(item: WindowItem, windowID: CGWindowID)]], of apps: [AppInfo],
                                stacking: [CGWindowID: Int]) -> [WindowItem] {
        let offScreen = offScreenWindows(notIn: stacking)
        var onScreen: [(z: Int, recency: Int, item: WindowItem)] = []
        // Keyed by app recency, then the app's own row before its windows.
        var elsewhere: [(key: (Int, Int), item: WindowItem)] = []
        var putAway: [(key: (Int, Int), item: WindowItem)] = []

        for (appIndex, app) in apps.enumerated() {
            let found = perApp[appIndex]
            var hasWindowToShow = false
            for (windowIndex, entry) in found.enumerated() {
                let key = (app.recency, 1 + windowIndex)
                if entry.item.isMinimized || app.isHidden {
                    putAway.append((key, entry.item))
                } else if let z = stacking[entry.windowID] {
                    onScreen.append((z, app.recency, entry.item))
                    hasWindowToShow = true
                } else {
                    elsewhere.append((key, entry.item))
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

    private static func windows(of app: AppInfo) -> [(item: WindowItem, windowID: CGWindowID)] {
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
            let item = WindowItem(
                id: "\(app.pid)-\(windowID)-\(index)",
                pid: app.pid,
                appName: app.name,
                title: attribute(window, kAXTitleAttribute) as? String ?? "",
                element: window,
                isMinimized: attribute(window, kAXMinimizedAttribute) as? Bool ?? false,
                isAppHidden: app.isHidden
            )
            return (item, windowID)
        }
    }

    /// The app's front window as a row `focus` can raise, or an app-only row if Accessibility can't see one.
    static func frontWindow(of pid: pid_t) -> WindowItem {
        let app = NSRunningApplication(processIdentifier: pid)
        let info = AppInfo(pid: pid, name: app?.localizedName ?? "Unknown", isHidden: app?.isHidden ?? false, recency: 0)
        return windows(of: info).first?.item
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
        // Services, the same route as clicking the app in the Dock.
        let madeFrontmost = AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(item.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue
        ) == .success
        if !madeFrontmost, let url = app?.bundleURL {
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
