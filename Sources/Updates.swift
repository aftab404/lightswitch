import AppKit

/// A dotted version number such as "1.1" or a tag such as "v1.10.2", compared number by number:
/// "1.10" is newer than "1.9", and "1.1" equals "1.1.0".
struct Version: Comparable, CustomStringConvertible {
    let numbers: [Int]

    init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        // Only the number part of "1.2-beta" or "1.2 (3)".
        let parts = text.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
            .split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !numbers.isEmpty, numbers.count == parts.count else { return nil }
        self.numbers = numbers
    }

    var description: String { numbers.map(String.init).joined(separator: ".") }

    static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}

/// Check for Updates…: asks GitHub for the latest release and offers it if it's newer than this copy.
/// This is the only network request Lightswitch makes, and only when the user chooses the menu item; it never checks on its own.
@MainActor
enum Updates {
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/aftab404/lightswitch/releases/latest")!
    static let download = URL(string: "https://github.com/aftab404/lightswitch/releases/latest/download/Lightswitch.dmg")!
    static let releases = URL(string: "https://github.com/aftab404/lightswitch/releases")!

    struct Release {
        let version: Version
        let page: URL
        let notes: String
    }

    enum Failure: Error {
        case offline
        case rateLimited(until: Date?)
        case unexpected(String)
    }

    private(set) static var isChecking = false

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    private static let offlineErrors: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed,
    ]

    static func check() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            let result = await latest(from: latestReleaseAPI)
            isChecking = false
            let (alert, links) = makeAlert(for: result)
            show(alert, links: links)
        }
    }

    static func latest(from url: URL) async -> Swift.Result<Release, Failure> {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub wants a user agent; the default one would also name the CFNetwork and Darwin versions.
        request.setValue("Lightswitch/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where offlineErrors.contains(error.code) {
            return .failure(.offline)
        } catch {
            return .failure(.unexpected(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.unexpected("GitHub didn't answer.")) }

        // Without an account GitHub answers 60 requests an hour per network, then says when it will again.
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
        let rateLimited = http.statusCode == 429
            || http.statusCode == 403 && (http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || retryAfter != nil)

        switch http.statusCode {
        case 200:
            break
        case _ where rateLimited:
            let until = retryAfter.map { Date(timeIntervalSinceNow: $0) } ?? reset.map { Date(timeIntervalSince1970: $0) }
            return .failure(.rateLimited(until: until))
        case 404:
            return .failure(.unexpected("GitHub has no release of Lightswitch."))
        default:
            return .failure(.unexpected("GitHub answered with error \(http.statusCode)."))
        }

        struct LatestRelease: Decodable {
            let tagName: String
            let htmlURL: URL?
            let body: String?
            enum CodingKeys: String, CodingKey { case tagName = "tag_name", htmlURL = "html_url", body }
        }
        guard let release = try? JSONDecoder().decode(LatestRelease.self, from: data) else {
            return .failure(.unexpected("GitHub's answer couldn't be read."))
        }
        guard let version = Version(release.tagName) else {
            return .failure(.unexpected("The latest release has an unexpected version, “\(release.tagName)”."))
        }
        return .success(Release(version: version, page: release.htmlURL ?? releases, notes: release.body ?? ""))
    }

    /// The alert for the outcome of a check, and the link each of its buttons opens (nil: just closes it).
    static func makeAlert(for result: Swift.Result<Release, Failure>) -> (NSAlert, links: [URL?]) {
        let alert = NSAlert()
        var links: [URL?] = []
        switch result {
        case .success(let release):
            let current = Version(AppInfo.version)
            if let current, release.version <= current {
                alert.messageText = "You're up to date"
                alert.informativeText = release.version == current
                    ? "Lightswitch \(current) is the latest version."
                    : "This copy of Lightswitch (\(current)) is newer than the latest release, \(release.version)."
                alert.addButton(withTitle: "OK")
            } else {
                alert.messageText = "Lightswitch \(release.version) is available"
                alert.informativeText = "You have \(current?.description ?? AppInfo.version). To update, quit Lightswitch, "
                    + "open the downloaded disk image and drag Lightswitch into Applications, replacing the old copy. "
                    + "macOS then asks you to confirm the new version with Open Anyway, and the welcome window helps you "
                    + "allow Accessibility again."
                if let notes = notesView(release.notes) { alert.accessoryView = notes }
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "View Release")
                alert.addButton(withTitle: "Later").keyEquivalent = "\u{1b}"
                links = [download, release.page]
            }
        case .failure(.offline):
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "Lightswitch couldn't reach GitHub. Check your internet connection and try again."
            alert.addButton(withTitle: "OK")
        case .failure(let failure):
            alert.messageText = "Couldn't check for updates"
            if case .rateLimited(let until) = failure {
                let when = until.flatMap { $0.timeIntervalSinceNow < 20 * 3600 ? $0 : nil }
                    .map { "after \($0.formatted(date: .omitted, time: .shortened))" } ?? "later"
                alert.informativeText = "GitHub only answers so many update checks from one network each hour, and that "
                    + "limit has been reached. Try again \(when), or look for a newer version on GitHub."
            } else if case .unexpected(let reason) = failure {
                alert.informativeText = "\(reason) You can look for a newer version on GitHub instead."
            }
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "View Releases")
            links = [nil, releases]
        }
        return (alert, links)
    }

    /// Runs `alert` in front, then opens the link of the button that was clicked, if it has one,
    /// or otherwise hands focus back to the app the user was in.
    private static func show(_ alert: NSAlert, links: [URL?]) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let previousApp = frontmost == .current ? nil : frontmost
        NSApp.activate()
        let button = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if links.indices.contains(button), let url = links[button] {
            NSWorkspace.shared.open(url)
        } else if NSApp.isActive {
            previousApp?.activate()
        }
    }

    // MARK: Release notes

    /// The release notes in a small scrolling box for the alert, or nil if there are none.
    private static func notesView(_ markdown: String) -> NSView? {
        let notes = attributedNotes(markdown)
        guard notes.length > 0 else { return nil }
        let width: CGFloat = 380, maxHeight: CGFloat = 180, inset = NSSize(width: 6, height: 8)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: maxHeight))
        textView.isEditable = false
        textView.textContainerInset = inset
        textView.textStorage?.setAttributedString(notes)
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        layout.ensureLayout(for: container)
        let height = min(layout.usedRect(for: container).height + 2 * inset.height + 2, maxHeight)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        return scrollView
    }

    /// GitHub release notes are Markdown: headings, bullets and inline bold, code and links are enough for ours.
    static func attributedNotes(_ markdown: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let result = NSMutableAttributedString()
        var pendingGap = false
        for rawLine in markdown.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                pendingGap = result.length > 0
                continue
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = pendingGap ? 6 : 2
            pendingGap = false
            var lineFont = font
            var prefix = ""
            if let hashes = line.firstIndex(where: { $0 != "#" }), hashes != line.startIndex, line[hashes] == " " {
                line = String(line[hashes...]).trimmingCharacters(in: .whitespaces)
                lineFont = .boldSystemFont(ofSize: NSFont.systemFontSize)
                paragraph.paragraphSpacingBefore = result.length > 0 ? 8 : 0
            } else if ["- ", "* ", "+ "].contains(where: line.hasPrefix) {
                line = String(line.dropFirst(2))
                prefix = "•\t"
                let indent: CGFloat = 12
                paragraph.headIndent = indent
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            }
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            let start = result.length
            result.append(NSAttributedString(string: prefix, attributes: [.font: lineFont]))
            result.append(inline(line, font: lineFont))
            result.addAttributes([.paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor],
                                 range: NSRange(location: start, length: result.length - start))
        }
        // Bare addresses aren't Markdown links, but should still open.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let all = NSRange(location: 0, length: result.length)
            for match in detector.matches(in: result.string, range: all) {
                if let url = match.url, result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil {
                    result.addAttribute(.link, value: url, range: match.range)
                }
            }
        }
        return result
    }

    private static func inline(_ markdown: String, font: NSFont) -> NSAttributedString {
        guard let parsed = try? AttributedString(
            markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return NSAttributedString(string: markdown, attributes: [.font: font]) }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
            } else if intent.contains(.stronglyEmphasized) {
                runFont = .boldSystemFont(ofSize: font.pointSize)
            }
            if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont]
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}
