import AppKit

/// This copy of Lightswitch and the Mac it runs on, for update checks and problem reports.
enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown" }

    /// "macOS 15.4.1 (24E263)".
    static var macOS: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var text = "macOS \(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
        if let build = sysctlString("kern.osversion") { text += " (\(build))" }
        return text
    }

    /// "Apple silicon Mac" or "Intel Mac", and whether this universal app is running under Rosetta.
    static var mac: String {
        // Rosetta reports the translated architecture to the app, but not to these.
        let appleSilicon = sysctlInt("hw.optional.arm64") == 1
        let translated = sysctlInt("sysctl.proc_translated") == 1
        return (appleSilicon ? "Apple silicon Mac" : "Intel Mac") + (translated ? ", Lightswitch running under Rosetta" : "")
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

@MainActor
enum About {
    static let site = URL(string: "https://aftab404.github.io/lightswitch/")!
    static let newIssue = URL(string: "https://github.com/aftab404/lightswitch/issues/new")!

    /// The standard About panel (name, icon, version, copyright from Info.plist) with the license and a link to the site.
    static func showPanel() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString(
            string: "Free and open source under the MIT License.\n",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centered]
        )
        credits.append(NSAttributedString(
            string: "aftab404.github.io/lightswitch",
            attributes: [.font: font, .link: site, .paragraphStyle: centered]
        ))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// Opens a new GitHub issue in the browser with the versions filled in. Nothing is sent until the user submits it there,
    /// and the report holds nothing about their windows, tabs or apps.
    static func reportProblem() {
        NSWorkspace.shared.open(problemReportURL)
    }

    static var problemReportURL: URL {
        let body = """
            <!-- Thanks for reporting! Screenshots or a screen recording help: drag them in here. \
            Leave out anything private, such as window or tab titles you'd rather not share. -->

            ### What happened?



            ### What did you expect to happen?



            ### Steps to reproduce



            ---
            - Lightswitch \(AppInfo.version) (\(AppInfo.build))
            - \(AppInfo.macOS)
            - \(AppInfo.mac)
            """
        // Stricter than URLComponents, which leaves "&", "=" and "+" in a query value as they are.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: newIssue.absoluteString + "?body=" + encoded) ?? newIssue
    }
}
