import AppKit

/// An app bundle the panel can open.
struct InstalledApp {
    let url: URL
    /// `url` with symlinks resolved, which is how running apps report it (/Applications/Safari.app is a link).
    let path: String
    /// The name Finder shows.
    let name: String
    /// What queries match: the name, then the bundle's own name when it differs ("Siri AI.app" shows as "Siri").
    let searchText: [Character]

    /// The folder it's in, for the row's second line. Finder hides the ".localized" on folders like "Chrome Apps".
    var folder: String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            .replacingOccurrences(of: ".localized", with: "")
    }
}

/// The apps in the usual Applications folders, so the panel can open ones that aren't running. Listing the
/// folders directly takes a few milliseconds, so there's no need to ask Spotlight. Its state is only touched
/// on the main thread.
enum InstalledApps {
    /// Called after each rescan.
    static var onUpdate: @MainActor () -> Void = {}

    private static var all: [InstalledApp] = []
    private static var scanned: (date: Date, folderDates: [Date?])?
    private static var isScanning = false
    private static var icons: [String: NSImage] = [:]

    private static let maxAge: TimeInterval = 3 * 60
    private static let folders = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
    private static let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    /// Rescans in the background if the list is a few minutes old, or right away if an Applications folder
    /// changed since, so an app that was just installed shows up.
    static func refreshIfStale() {
        guard !isScanning else { return }
        let folderDates = folders.map { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
        if let scanned, -scanned.date.timeIntervalSinceNow < maxAge, scanned.folderDates == folderDates { return }

        isScanning = true
        DispatchQueue.global(qos: .utility).async {
            let apps = scan()
            DispatchQueue.main.async {
                all = apps
                icons = [:] // an update may have changed one
                scanned = (Date(), folderDates)
                isScanning = false
                onUpdate()
            }
        }
    }

    /// The apps without a row of their own: running ones are listed with their windows already,
    /// and opening Lightswitch from itself would do nothing useful.
    static var launchable: [InstalledApp] {
        var running = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })
        running.insert(Bundle.main.bundleURL.resolvingSymlinksInPath().path)
        return all.filter { !running.contains($0.path) }
    }

    static func icon(for app: InstalledApp) -> NSImage {
        if let icon = icons[app.path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icons[app.path] = icon
        return icon
    }

    static func open(_ app: InstalledApp) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let path = app.url.path
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { _, error in
            if let error { NSLog("Lightswitch: could not open \(path): \(error)") }
        }
    }

    private static func scan() -> [InstalledApp] {
        var urls = [finder]
        for folder in folders {
            // Not .skipsHiddenFiles: the Safari link in /Applications is flagged hidden.
            guard let entries = FileManager.default.enumerator(
                at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.localizedNameKey],
                options: .skipsPackageDescendants
            ) else { continue }
            for case let url as URL in entries {
                if url.pathExtension == "app" {
                    urls.append(url)
                } else if entries.level > 1 || url.lastPathComponent.hasPrefix(".") {
                    // Apps one folder down count (Utilities, vendor folders); deeper ones are mostly helpers and plug-ins.
                    entries.skipDescendants()
                }
            }
        }

        var seen = Set<String>()
        return urls.compactMap { url -> InstalledApp? in
            let path = url.resolvingSymlinksInPath().path
            guard seen.insert(path).inserted else { return nil }
            let bundleName = url.deletingPathExtension().lastPathComponent
            var name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? bundleName
            if name.hasSuffix(".app") { name.removeLast(4) } // Finder set to show all extensions
            let searchText = name == bundleName ? name : name + " " + bundleName
            return InstalledApp(url: url, path: path, name: name, searchText: Array(searchText))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
