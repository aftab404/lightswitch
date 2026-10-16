import AppKit
import CoreServices

/// A tab in one of the browsers Lightswitch can read over Apple Events.
struct BrowserTab {
    let pid: pid_t
    let browserName: String
    let icon: NSImage?
    fileprivate let dialect: Dialect
    fileprivate let window: WindowRef
    /// Its window's titles when it was read: its name in the browser's scripting, and its current tab's title.
    /// Accessibility's title for the window is one of them, maybe followed by the browser's name.
    let windowTitles: [String]
    /// Its window's place in the browser's own front-to-back order.
    let windowOrder: Int
    /// Its position in the window, from 1.
    let index: Int
    /// Whether it's the tab its window shows, which makes it that window's row.
    let isActive: Bool
    /// The page title, or the address of a page without one.
    let title: String
    let url: String
    /// The host without "www." (and with any port), for the row's second line.
    let domain: String
    /// "domain · Browser name".
    let subtitle: String
    /// Where the browser name starts in `subtitle`.
    let browserNameOffset: Int
    /// The title and browser name, which queries match like a window's title and app name.
    let nameText: Fuzzy.Text
    /// The domain and path, where a query term only counts if it appears unbroken.
    let addressText: Fuzzy.Text
    /// Where the top-level domain (".com") is in `addressText`. A term starting there doesn't count,
    /// or "com" would match nearly every tab.
    let topLevelDomain: Range<Int>?

    var id: String { "tab-\(pid)-\(window)-\(index)" }

    /// Whether `other` is this tab, as read at another time, still in the same place.
    fileprivate func isSame(as other: BrowserTab) -> Bool {
        window == other.window && index == other.index && url == other.url && title == other.title
    }

    fileprivate init(browser: RunningBrowser, dialect: Dialect, window: ListedWindow, windowOrder: Int,
                     index: Int, title: String, url: String) {
        pid = browser.pid
        browserName = browser.name
        icon = browser.icon
        self.dialect = dialect
        self.window = window.ref
        windowTitles = Array(Set([window.name, window.activeTitle].compactMap { $0 }.filter { !$0.isEmpty }))
        self.windowOrder = windowOrder
        self.index = index
        isActive = index == window.activeTab
        self.url = url

        let components = URLComponents(string: url)
        var host = components?.host ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var domain = host
        if let port = components?.port { domain += ":\(port)" }
        self.domain = domain
        var address = url // about:blank, file:///…
        if !host.isEmpty {
            let path = components?.path ?? ""
            address = path == "/" ? domain : domain + path
        }
        topLevelDomain = host.lastIndex(of: ".").flatMap { dot in
            // Not the last part of an IP address.
            host[host.index(after: dot)...].contains(where: \.isLetter)
                ? host.distance(from: host.startIndex, to: dot) ..< host.count : nil
        }

        self.title = title.isEmpty ? (address.isEmpty ? "Untitled" : address) : title
        subtitle = domain.isEmpty ? browser.name : domain + " · " + browser.name
        browserNameOffset = domain.isEmpty ? 0 : domain.count + 3
        nameText = Fuzzy.Text(Array(self.title) + [" "] + Array(browser.name))
        addressText = Fuzzy.Text(Array(address))
    }

    #if DEMO
    /// Made-up tabs of one browser window for demo recordings, in the order the window has them. `active` is the
    /// current tab's position, from 1.
    static func samples(pid: pid_t, browserName: String, icon: NSImage?, windowOrder: Int,
                        tabs: [(title: String, url: String)], active: Int) -> [BrowserTab] {
        let browser = RunningBrowser(pid: pid, name: browserName, icon: icon, bundleURL: nil, family: .safari)
        let window = ListedWindow(ref: .index(windowOrder), name: tabs[active - 1].title, activeTab: active, tabs: tabs)
        return tabs.enumerated().map { offset, tab in
            BrowserTab(browser: browser, dialect: .safari, window: window, windowOrder: windowOrder,
                       index: offset + 1, title: tab.title, url: tab.url)
        }
    }
    #endif
}

/// Lists the tabs of running browsers and switches to them, over Apple Events. Its state is only touched on the
/// main thread.
///
/// It talks to browsers with raw Apple Events rather than AppleScript: NSAppleScript is main-thread only, while
/// raw events can be sent from a background queue and give up after a timeout, so a hung browser can't stall
/// anything. They're addressed by process ID, which can't launch a browser that isn't running.
enum BrowserTabs {
    /// Called on the main thread after each read of a browser's tabs, with nil if they couldn't be read.
    static var onUpdate: @MainActor (_ pid: pid_t, _ tabs: [BrowserTab]?) -> Void = { _, _ in }

    private static let browsers: [String: Family] = [
        "com.google.Chrome": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "org.chromium.Chromium": .chromium,
        "company.thebrowser.Browser": .arc,
        "com.apple.Safari": .safari,
    ]

    private static var reading: Set<pid_t> = []
    /// The last error logged for each browser, so a denied permission isn't logged on every open.
    private static var loggedErrors: [pid_t: Int] = [:]

    /// Starts reading the tabs of every supported browser that's running, unless a read of it is still going.
    /// Without `askingPermission`, a browser the user hasn't been asked about yet is skipped rather than prompted for.
    /// Returns the browsers being read, each of which will call `onUpdate`.
    @discardableResult
    static func refresh(askingPermission: Bool = true) -> Set<pid_t> {
        for browser in runningBrowsers() where reading.insert(browser.pid).inserted {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try read(browser, askingPermission: askingPermission) }
                DispatchQueue.main.async {
                    reading.remove(browser.pid)
                    switch result {
                    case .success(let tabs):
                        loggedErrors[browser.pid] = nil
                        onUpdate(browser.pid, tabs)
                    case .failure(let failure):
                        onUpdate(browser.pid, nil)
                        // Most likely the user said no to the permission prompt. The window rows stay, so just log it.
                        let error = failure as? AppleEventError ?? AppleEventError(code: Int(errAEEventFailed))
                        guard loggedErrors[browser.pid] != error.code else { return }
                        loggedErrors[browser.pid] = error.code
                        NSLog("Lightswitch: could not read the tabs of \(browser.name): \(error)")
                    }
                }
            }
        }
        return reading
    }

    /// How well `title`, a window's title from Accessibility, fits `tab`'s window: the length of the window title
    /// it is or starts with, so higher is closer, or nil if it's another window. Chromium browsers shorten long
    /// window names in the middle for scripting, while Accessibility gets the current tab's full title with the
    /// browser's name added: "Inbox - Google Chrome" for "Inbox".
    static func windowTitleFit(_ title: String, _ tab: BrowserTab) -> Int? {
        tab.windowTitles.filter { title == $0 || title.hasPrefix($0 + " - ") }.map(\.count).max()
    }

    /// Makes `tab` the one its window shows and puts that window in front of the browser's others, then calls
    /// back on the main thread, whether or not that worked.
    static func select(_ tab: BrowserTab, completion: @escaping @MainActor () -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            let events = AppleEvents(pid: tab.pid)
            let window = tab.window.specifier
            do {
                switch tab.dialect {
                case .chromium:
                    try events.set(.property(Code.activeTabIndex, of: window), to: NSAppleEventDescriptor(int32: Int32(tab.index)))
                case .safari:
                    try events.set(.property(Code.currentTab, of: window), to: .element(Code.safariTab, index: tab.index, of: window))
                case .arc(let terms):
                    try events.send(terms.select, .element(terms.tab, index: tab.index, of: window))
                }
                // A minimized window would stay in the Dock. Safari calls it "miniaturized", with the same code.
                try? events.set(.property(Code.minimized, of: window), to: NSAppleEventDescriptor(boolean: false))
                try? events.set(.property(Code.index, of: window), to: NSAppleEventDescriptor(int32: 1))
            } catch {
                NSLog("Lightswitch: could not switch to the \(tab.browserName) tab: \(error)")
            }
            DispatchQueue.main.async { completion() }
        }
    }

    /// Closes `tab`, then calls back on the main thread with its browser's tabs as they are afterwards, or nil if it
    /// couldn't be closed. The tab is looked up again first: closing a tab moves the ones after it in its window up a
    /// place, so the panel's copy may be behind. Closes run one at a time for that reason. A page that asks whether to
    /// leave keeps its tab until the user answers.
    static func close(_ tab: BrowserTab, completion: @escaping @MainActor ([BrowserTab]?) -> Void) {
        let browser = runningBrowsers().first { $0.pid == tab.pid }
        closing.async {
            var result: [BrowserTab]?
            do {
                guard let browser else { throw AppleEventError(code: Int(procNotFound)) }
                var tabs = try read(browser, askingPermission: false)
                if let target = counterpart(of: tab, in: tabs) {
                    let window = target.window.specifier
                    try AppleEvents(pid: tab.pid).send(target.dialect.close, .element(target.dialect.tab, index: target.index, of: window))
                    // The browser may take a moment to let go of it.
                    let deadline = Date() + 0.5
                    while tabs.contains(where: { $0.isSame(as: target) }), Date() < deadline {
                        usleep(50_000)
                        tabs = try read(browser, askingPermission: false)
                    }
                }
                result = tabs
            } catch {
                NSLog("Lightswitch: could not close the \(tab.browserName) tab: \(error)")
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static let closing = DispatchQueue(label: "Lightswitch.closing-tabs", qos: .userInitiated)

    /// `tab` in a newer read of its browser: the tab in the same window with the same address, preferably with the
    /// same title too, nearest its old place.
    private static func counterpart(of tab: BrowserTab, in tabs: [BrowserTab]) -> BrowserTab? {
        func distance(_ other: BrowserTab) -> (Int, Int) {
            (other.title == tab.title ? 0 : 1, abs(other.index - tab.index))
        }
        return tabs.filter { $0.window == tab.window && $0.url == tab.url }.min { distance($0) < distance($1) }
    }

    private static func runningBrowsers() -> [RunningBrowser] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier, let family = browsers[bundleID], !app.isTerminated else { return nil }
            return RunningBrowser(pid: app.processIdentifier, name: app.localizedName ?? bundleID,
                                  icon: app.icon, bundleURL: app.bundleURL, family: family)
        }
    }

    // MARK: Reading

    private static func read(_ browser: RunningBrowser, askingPermission: Bool) throws -> [BrowserTab] {
        let events = AppleEvents(pid: browser.pid)
        try events.requestPermission(ask: askingPermission)

        let dialect: Dialect
        let windows: [ListedWindow]
        switch browser.family {
        case .chromium:
            dialect = .chromium
            windows = try chromiumWindows(events)
        case .safari:
            dialect = .safari
            windows = try safariWindows(events)
        case .arc:
            guard let terms = ArcTerms(app: browser.bundleURL) else { throw AppleEventError(code: Int(errAEEventNotHandled)) }
            dialect = .arc(terms)
            windows = try arcWindows(events, terms: terms)
        }

        return windows.enumerated().flatMap { order, window in
            window.tabs.enumerated().map { offset, page in
                BrowserTab(browser: browser, dialect: dialect, window: window, windowOrder: order,
                           index: offset + 1, title: page.title, url: page.url)
            }
        }
    }

    /// Chromium answers for all windows at once, a column per event.
    private static func chromiumWindows(_ events: AppleEvents) throws -> [ListedWindow] {
        let windows = NSAppleEventDescriptor.every(Code.window)
        let tabs = NSAppleEventDescriptor.every(Code.chromiumTab, of: windows)
        let ids = try events.get(.property(Code.id, of: windows)).listItems
        let names = try events.get(.property(Code.name, of: windows)).listItems
        let active = try events.get(.property(Code.activeTabIndex, of: windows)).listItems
        let titles = try events.get(.property(Code.name, of: tabs)).listItems
        let urls = try events.get(.property(Code.chromiumURL, of: tabs)).listItems
        // A window opened or closed between two of the events.
        guard [names.count, active.count, titles.count, urls.count].allSatisfy({ $0 == ids.count }) else {
            throw AppleEventError(code: AppleEventError.changedWhileReading)
        }

        return ids.indices.compactMap { i in
            let windowTitles = titles[i].listItems, windowURLs = urls[i].listItems
            guard windowTitles.count == windowURLs.count else { return nil }
            return ListedWindow(ref: WindowRef(id: ids[i]), name: names[i].text, activeTab: Int(active[i].int32Value),
                                tabs: zip(windowTitles, windowURLs).map { (title: $0.text, url: $1.text) })
        }
    }

    /// Safari's windows include ones without tabs, like Settings, so tabs are read a window at a time.
    private static func safariWindows(_ events: AppleEvents) throws -> [ListedWindow] {
        let windows = NSAppleEventDescriptor.every(Code.window)
        let ids = try events.get(.property(Code.id, of: windows)).listItems
        let names = try events.get(.property(Code.name, of: windows)).listItems
        guard names.count == ids.count else { throw AppleEventError(code: AppleEventError.changedWhileReading) }

        return try ids.indices.compactMap { i in
            let ref = WindowRef(id: ids[i])
            let window = ref.specifier
            let tabs = NSAppleEventDescriptor.every(Code.safariTab, of: window)
            return try skippingWindowErrors {
                let titles = try events.get(.property(Code.name, of: tabs)).listItems
                let urls = try events.get(.property(Code.safariURL, of: tabs)).listItems
                let active = try events.get(.property(Code.index, of: .property(Code.currentTab, of: window)))
                guard titles.count == urls.count else { return nil }
                return ListedWindow(ref: ref, name: names[i].text, activeTab: Int(active.int32Value),
                                    tabs: zip(titles, urls).map { (title: $0.text, url: $1.text) })
            }
        }
    }

    /// Arc can't find a window again by its ID, so windows go by position, and it marks the current tab by ID.
    private static func arcWindows(_ events: AppleEvents, terms: ArcTerms) throws -> [ListedWindow] {
        let names = try events.get(.property(Code.name, of: .every(Code.window))).listItems
        return try names.indices.compactMap { i in
            let ref = WindowRef.index(i + 1)
            let window = ref.specifier
            let tabs = NSAppleEventDescriptor.every(terms.tab, of: window)
            return try skippingWindowErrors {
                let titles = try events.get(.property(terms.title, of: tabs)).listItems
                let urls = try events.get(.property(terms.url, of: tabs)).listItems
                let ids = try events.get(.property(terms.id, of: tabs)).listItems.map(\.text)
                let activeID = try? events.get(.property(terms.id, of: .property(terms.activeTab, of: window))).text
                guard titles.count == urls.count, urls.count == ids.count else { return nil }
                let activeTab = ids.firstIndex { $0 == activeID }.map { $0 + 1 } ?? 0
                return ListedWindow(ref: ref, name: names[i].text, activeTab: activeTab,
                                    tabs: zip(titles, urls).map { (title: $0.text, url: $1.text) })
            }
        }
    }

    /// Runs `read` for one window, leaving the window out if it can't be read (one without tabs, say).
    /// Errors that mean the whole browser can't be read still end the read.
    private static func skippingWindowErrors(_ read: () throws -> ListedWindow?) throws -> ListedWindow? {
        do {
            return try read()
        } catch let error as AppleEventError where !error.isFatal {
            return nil
        }
    }
}

// MARK: Permission

extension BrowserTabs {
    /// A supported browser that's running.
    struct Browser {
        let pid: pid_t
        let name: String
        let icon: NSImage?
    }

    /// Whether macOS lets Lightswitch send a browser Apple Events, which reading its tabs takes.
    enum Permission {
        case allowed, denied
        /// The user hasn't been asked yet.
        case notAsked
        /// macOS couldn't say, for example because the browser has quit.
        case unknown
    }

    /// The supported browsers that are running, by name.
    static var running: [Browser] {
        runningBrowsers()
            .map { Browser(pid: $0.pid, name: $0.name, icon: $0.icon) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Finds out whether Lightswitch may read `pid`'s tabs and calls back on the main thread. With `ask`, macOS's
    /// "Lightswitch wants access to control …" prompt comes first if the user hasn't answered it yet, and the
    /// callback waits for their answer.
    static func permission(of pid: pid_t, ask: Bool, completion: @escaping @MainActor (Permission) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let permission: Permission = switch Int(AppleEvents(pid: pid).permission(ask: ask)) {
            case Int(noErr): .allowed
            case Int(errAEEventNotPermitted): .denied
            case Int(errAEEventWouldRequireUserConsent): .notAsked
            default: .unknown
            }
            DispatchQueue.main.async { completion(permission) }
        }
    }
}

// MARK: Browsers

private struct RunningBrowser {
    let pid: pid_t
    let name: String
    let icon: NSImage?
    let bundleURL: URL?
    let family: BrowserTabs.Family
}

extension BrowserTabs {
    fileprivate enum Family { case chromium, safari, arc }
}

/// How a browser's scripting dictionary spells what Lightswitch needs.
private enum Dialect {
    case chromium
    case safari
    case arc(ArcTerms)

    /// The tab class.
    var tab: OSType {
        switch self {
        case .chromium: Code.chromiumTab
        case .safari: Code.safariTab
        case .arc(let terms): terms.tab
        }
    }

    var close: (eventClass: AEEventClass, eventID: AEEventID) {
        switch self {
        case .chromium, .safari: Code.close
        case .arc(let terms): terms.close
        }
    }
}

private struct ListedWindow {
    let ref: WindowRef
    let name: String
    /// The current tab's position, from 1, or 0 if unknown.
    let activeTab: Int
    let tabs: [(title: String, url: String)]

    var activeTitle: String? {
        tabs.indices.contains(activeTab - 1) ? tabs[activeTab - 1].title : nil
    }
}

/// How to find a window again when switching to one of its tabs.
private enum WindowRef: Equatable, CustomStringConvertible {
    case number(Int32)
    case text(String)
    case index(Int)

    /// Chromium's dictionary says window IDs are text, Safari's says integers. Hand back whatever came.
    init(id: NSAppleEventDescriptor) {
        switch id.descriptorType {
        case DescType(typeUnicodeText), DescType(typeUTF8Text), DescType(typeChar): self = .text(id.text)
        default: self = .number(id.int32Value)
        }
    }

    var specifier: NSAppleEventDescriptor {
        switch self {
        case .number(let id): .element(Code.window, id: NSAppleEventDescriptor(int32: id))
        case .text(let id): .element(Code.window, id: NSAppleEventDescriptor(string: id))
        case .index(let index): .element(Code.window, index: index)
        }
    }

    var description: String {
        switch self {
        case .number(let id): "\(id)"
        case .text(let id): id
        case .index(let index): "#\(index)"
        }
    }
}

/// Four-character codes from the browsers' scripting dictionaries (`sdef /Applications/Safari.app`).
private enum Code {
    // Standard Suite, the same for every browser here.
    static let window = fourCharCode("cwin")
    static let id = fourCharCode("ID  ")
    static let name = fourCharCode("pnam") // also a Chromium tab's title and a Safari tab's name
    static let index = fourCharCode("pidx")
    static let minimized = fourCharCode("pmnd")
    static let close = (eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEClose))
    // Chromium's scripting.sdef, which Chrome, Brave, Edge, Vivaldi and Chromium all ship.
    static let chromiumTab = fourCharCode("CrTb")
    static let chromiumURL = fourCharCode("URL ")
    static let activeTabIndex = fourCharCode("acTI")
    // Safari.sdef
    static let safariTab = fourCharCode("bTab")
    static let safariURL = fourCharCode("pURL")
    static let currentTab = fourCharCode("cTab")
}

/// Arc's dictionary is its own, not Chromium's: its window has a read-only "active tab" and a tab is
/// switched to with a "select" command. The codes are read from the dictionary in Arc's bundle.
private struct ArcTerms {
    let tab: OSType
    let title: OSType
    let url: OSType
    let id: OSType
    let activeTab: OSType
    let select: (eventClass: AEEventClass, eventID: AEEventID)
    /// The Standard Suite's close unless the dictionary says otherwise.
    let close: (eventClass: AEEventClass, eventID: AEEventID)

    init?(app: URL?) {
        guard let app, let bundle = Bundle(url: app),
              let file = bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String,
              let url = bundle.resourceURL?.appendingPathComponent(file),
              let sdef = try? XMLDocument(contentsOf: url) else { return nil }
        func code(_ path: String) -> String? {
            (try? sdef.nodes(forXPath: path))?.first?.stringValue
        }
        let tab = "//class[@name='tab']"
        guard let tabCode = code("\(tab)/@code"), tabCode.utf8.count == 4,
              let title = code("\(tab)/property[@name='title']/@code"), title.utf8.count == 4,
              let url = code("\(tab)/property[@name='URL']/@code"), url.utf8.count == 4,
              let id = code("\(tab)/property[@name='id']/@code"), id.utf8.count == 4,
              let activeTab = code("//*[@name='window' or @extends='window']/property[@name='active tab']/@code"),
              activeTab.utf8.count == 4,
              let select = code("//command[@name='select']/@code"), select.utf8.count == 8 else { return nil }
        self.tab = fourCharCode(tabCode)
        self.title = fourCharCode(title)
        self.url = fourCharCode(url)
        self.id = fourCharCode(id)
        self.activeTab = fourCharCode(activeTab)
        self.select = (fourCharCode(String(select.prefix(4))), fourCharCode(String(select.suffix(4))))
        if let close = code("//command[@name='close']/@code"), close.utf8.count == 8 {
            self.close = (fourCharCode(String(close.prefix(4))), fourCharCode(String(close.suffix(4))))
        } else {
            self.close = Code.close
        }
    }
}

private func fourCharCode(_ code: String) -> OSType {
    code.utf8.reduce(0) { $0 << 8 | OSType($1) }
}

// MARK: Apple Events

struct AppleEventError: Error, CustomStringConvertible {
    static let changedWhileReading = -1

    let code: Int

    /// Whether the app can't be talked to at all, rather than just one object being missing.
    var isFatal: Bool {
        [Int(errAEEventNotPermitted), Int(errAEEventWouldRequireUserConsent), Int(errAETimeout),
         Int(procNotFound), Int(connectionInvalid)].contains(code)
    }

    var description: String {
        switch code {
        case Self.changedWhileReading: "its windows changed while they were being read"
        case Int(errAEEventNotPermitted): "Lightswitch isn't allowed to control it (\(code))"
        case Int(errAEEventWouldRequireUserConsent): "Lightswitch hasn't asked to control it yet (\(code))"
        case Int(errAETimeout): "it didn't answer in time (\(code))"
        case Int(errAEEventNotHandled): "its scripting dictionary isn't one Lightswitch knows (\(code))"
        default: "Apple Event error \(code)"
        }
    }
}

/// Sends Apple Events to one app, waiting at most `timeout` for each answer.
private struct AppleEvents {
    let target: NSAppleEventDescriptor
    var timeout: TimeInterval = 2

    init(pid: pid_t) {
        target = NSAppleEventDescriptor(processIdentifier: pid)
    }

    /// noErr if Lightswitch may send it events, errAEEventNotPermitted if the user said no, and
    /// errAEEventWouldRequireUserConsent if they haven't been asked. With `ask`, that last case shows the
    /// "Lightswitch wants access to control …" prompt instead and blocks until they answer, so never ask on the main thread.
    func permission(ask: Bool) -> OSStatus {
        AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    /// Throws unless Lightswitch may send it events, asking the user first if `ask` (see `permission(ask:)`).
    func requestPermission(ask: Bool) throws {
        let status = permission(ask: ask)
        guard status == noErr else { throw AppleEventError(code: Int(status)) }
    }

    func get(_ specifier: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try send((AEEventClass(kAECoreSuite), AEEventID(kAEGetData)), specifier)
    }

    func set(_ specifier: NSAppleEventDescriptor, to value: NSAppleEventDescriptor) throws {
        try send((AEEventClass(kAECoreSuite), AEEventID(kAESetData)), specifier, data: value)
    }

    @discardableResult
    func send(_ event: (eventClass: AEEventClass, eventID: AEEventID), _ directObject: NSAppleEventDescriptor,
              data: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
        let message = NSAppleEventDescriptor(eventClass: event.eventClass, eventID: event.eventID, targetDescriptor: target,
                                             returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        message.setParam(directObject, forKeyword: AEKeyword(keyDirectObject))
        if let data { message.setParam(data, forKeyword: AEKeyword(keyAEData)) }
        let reply: NSAppleEventDescriptor
        do {
            reply = try message.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
        } catch {
            throw AppleEventError(code: (error as NSError).code)
        }
        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
            throw AppleEventError(code: Int(error.int32Value))
        }
        return reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) ?? .null()
    }
}

/// Object specifiers, the "name of every tab of window id 3" part of a script, built by hand.
private extension NSAppleEventDescriptor {
    static func every(_ type: OSType, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        var all = OSType(kAEAll)
        let ordinal = NSAppleEventDescriptor(descriptorType: DescType(typeAbsoluteOrdinal), bytes: &all, length: 4)!
        return specifier(type, form: OSType(formAbsolutePosition), data: ordinal, container)
    }

    static func element(_ type: OSType, index: Int, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        specifier(type, form: OSType(formAbsolutePosition), data: NSAppleEventDescriptor(int32: Int32(index)), container)
    }

    static func element(_ type: OSType, id: NSAppleEventDescriptor, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        specifier(type, form: OSType(formUniqueID), data: id, container)
    }

    static func property(_ code: OSType, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(OSType(typeProperty), form: OSType(formPropertyID), data: NSAppleEventDescriptor(typeCode: code), container)
    }

    private static func specifier(_ type: OSType, form: OSType, data: NSAppleEventDescriptor,
                                  _ container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier))!
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: type), forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        specifier.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return specifier
    }

    /// The items of a list (a single value counts as a list of one).
    var listItems: [NSAppleEventDescriptor] {
        guard descriptorType == DescType(typeAEList) else { return [self] }
        return numberOfItems == 0 ? [] : (1...numberOfItems).compactMap { atIndex($0) }
    }

    /// Text, with `missing value` (an unloaded tab's title, say) as "".
    var text: String {
        descriptorType == DescType(typeType) ? "" : stringValue ?? ""
    }
}
