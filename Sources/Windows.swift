import AppKit
import ApplicationServices

// Private but long-stable HIServices call that maps an AX window to its CGWindowID,
// which lets us order windows by their real on-screen stacking order.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt if access hasn't been granted yet.
    static func requestIfNeeded() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

struct WindowItem: Identifiable {
    let id: String
    let pid: pid_t
    let appName: String
    let title: String
    /// nil when the app has no windows we can reach (e.g. they're all on another Space).
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
        let recency: Int
    }

    /// Collects every window of every regular app, front-most first. Calls back on the main thread.
    static func fetch(completion: @escaping @MainActor ([WindowItem]) -> Void) {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isTerminated
        }
        let apps = running.enumerated().map { index, app in
            AppInfo(
                pid: app.processIdentifier,
                name: app.localizedName ?? "Unknown",
                isHidden: app.isHidden,
                recency: recentPIDs.firstIndex(of: app.processIdentifier) ?? (recentPIDs.count + index)
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

            // Sort key: on-screen windows by stacking order, then off-screen windows by app recency,
            // then apps without reachable windows.
            var keyed: [(key: (Int, Int, Int), item: WindowItem)] = []
            for (appIndex, app) in apps.enumerated() {
                let found = perApp[appIndex]
                if found.isEmpty {
                    let item = WindowItem(id: "app-\(app.pid)", pid: app.pid, appName: app.name, title: "",
                                          element: nil, isMinimized: false, isAppHidden: app.isHidden)
                    keyed.append(((2, app.recency, 0), item))
                    continue
                }
                for (windowIndex, entry) in found.enumerated() {
                    if let z = stacking[entry.windowID], !entry.item.isMinimized, !app.isHidden {
                        keyed.append(((0, z, 0), entry.item))
                    } else {
                        keyed.append(((1, app.recency, windowIndex), entry.item))
                    }
                }
            }
            keyed.sort { $0.key < $1.key }

            DispatchQueue.main.async {
                completion(keyed.map { entry in
                    var item = entry.item
                    item.icon = icons[item.pid] ?? nil
                    return item
                })
            }
        }
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

    private static func windows(of app: AppInfo) -> [(item: WindowItem, windowID: CGWindowID)] {
        let axApp = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3) // don't let a hung app stall the switcher
        guard let windows = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else { return [] }

        return windows.enumerated().compactMap { index, window in
            let subrole = attribute(window, kAXSubroleAttribute) as? String
            guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { return nil }
            var windowID: CGWindowID = 0
            _AXUIElementGetWindow(window, &windowID)
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
        // Our panel never activates Lightswitch, so ask via AX as well as the normal route.
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(item.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app?.activate()

        // Some apps reshuffle their windows on activation; raise once more after it settles.
        if let window = item.element {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }
    }
}
