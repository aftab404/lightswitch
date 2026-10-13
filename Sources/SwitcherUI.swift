import AppKit
import SwiftUI

enum Layout {
    static let width: CGFloat = 680
    static let searchHeight: CGFloat = 56
    static let rowHeight: CGFloat = 46
    static let sectionTitleHeight: CGFloat = 28
    static let listPadding: CGFloat = 8
    static let maxVisibleRows = 8
    static let cornerRadius: CGFloat = 26
    /// Transparent space around the card inside the window, so our own shadow isn't clipped.
    static let shadowMargin: CGFloat = 40

    /// Where the card's top edge sits on a screen, roughly where Spotlight appears.
    static func cardTop(on screen: NSScreen) -> CGFloat {
        screen.visibleFrame.maxY - screen.visibleFrame.height * 0.22
    }
}

// MARK: Model

@MainActor
final class SwitcherModel: ObservableObject {
    struct Result: Identifiable {
        enum Target {
            case window(WindowItem)
            case tab(BrowserTab)
            case app(InstalledApp)
        }

        let target: Target
        let id: String
        let title: String
        let subtitle: String
        let icon: NSImage?
        let badge: String?
        var titleHits: Set<Int> = []
        var subtitleHits: Set<Int> = []

        init(_ item: WindowItem) {
            target = .window(item)
            id = item.id
            title = item.displayTitle
            subtitle = item.appName
            icon = item.icon
            badge = item.badge
        }

        init(_ tab: BrowserTab) {
            target = .tab(tab)
            id = tab.id
            title = tab.title
            subtitle = tab.subtitle
            icon = tab.icon
            badge = nil
        }

        init(_ app: InstalledApp) {
            target = .app(app)
            id = app.path
            title = app.name
            subtitle = app.folder
            icon = InstalledApps.icon(for: app)
            badge = "Open"
        }
    }

    /// One or two letters match most installed apps, so only the best few are listed.
    private static let maxApps = 6
    /// The same goes for tabs other than the ones windows show, which can number in the hundreds.
    private static let maxOtherTabs = 10

    @Published var query = "" {
        didSet { if query != oldValue { refilter() } }
    }
    /// Matching windows and browser tabs, then matching apps that aren't running.
    @Published private(set) var results: [Result] = []
    /// Where the apps start in `results`, if any matched.
    private(set) var firstAppIndex: Int?
    @Published var selection = 0
    @Published private(set) var showCount = 0
    /// Without Accessibility access macOS hides window titles, so only app rows can be listed.
    @Published private(set) var needsAccessibility = false

    var items: [WindowItem] = [] {
        didSet { refilter() }
    }
    /// Installed apps to offer when the query matches them.
    var apps: [InstalledApp] = [] {
        didSet { refilter() }
    }
    /// The tabs of each browser that could be read, by pid. While typing they're listed in place of that
    /// browser's windows: a browser window's row is just its current tab.
    private var tabs: [pid_t: [BrowserTab]] = [:]
    /// For each of those browsers, one tab per window, to tell which window rows the tabs stand in for.
    private var tabWindows: [pid_t: [BrowserTab]] = [:]

    var onConfirm: (WindowItem) -> Void = { _ in }
    /// The tab, and its window's row if the window could be told apart from the browser's others by title.
    var onSwitchToTab: (BrowserTab, WindowItem?) -> Void = { _, _ in }
    var onOpen: (InstalledApp) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }

    var hasTabs: Bool { !tabs.isEmpty }

    /// The app that was frontmost when the panel opened. Its top window is the one the user is already in.
    private var currentAppPID: pid_t?

    // Must mirror SwitcherView's layout: each section below the search bar adds a 1pt separator.
    var height: CGFloat {
        var height = Layout.searchHeight
        if needsAccessibility {
            height += 1 + Layout.rowHeight
        }
        let rows = min(results.count, Layout.maxVisibleRows)
        if rows > 0 {
            height += 1 + CGFloat(rows) * Layout.rowHeight + Layout.listPadding * 2
            // The Applications title, unless it starts below the visible rows.
            if let firstAppIndex, firstAppIndex < Layout.maxVisibleRows {
                height += Layout.sectionTitleHeight
            }
        } else if !query.isEmpty {
            height += 1 + Layout.rowHeight
        }
        return height
    }

    func prepareForShow(currentApp: pid_t?) {
        currentAppPID = currentApp
        needsAccessibility = !Accessibility.isTrusted
        query = ""
        tabs = [:]
        tabWindows = [:]
        items = []
        showCount += 1
    }

    func setTabs(_ browserTabs: [BrowserTab], of pid: pid_t) {
        tabs[pid] = browserTabs
        tabWindows[pid] = browserTabs.filter { $0.index == 1 }
        guard !query.isEmpty else { return }
        // Tabs usually arrive a moment after the windows. If the user has already moved down to a row, keep it.
        let selected = selection > 0 && results.indices.contains(selection) ? results[selection].id : nil
        refilter()
        if let selected, let index = results.firstIndex(where: { $0.id == selected }) {
            selection = index
        }
    }

    func requestAccessibility() {
        onCancel()
        Accessibility.requestAgain()
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    func confirm() {
        guard results.indices.contains(selection) else { return }
        switch results[selection].target {
        case .window(let item): onConfirm(item)
        case .tab(let tab): onSwitchToTab(tab, window(of: tab))
        case .app(let app): onOpen(app)
        }
    }

    private func window(of tab: BrowserTab) -> WindowItem? {
        let matches = items.filter {
            $0.pid == tab.pid && $0.element != nil && BrowserTabs.windowTitle($0.title, matches: tab)
        }
        // For "Inbox", "Inbox - Google Chrome" rather than "Inbox - Gmail - Google Chrome".
        guard let shortest = matches.map(\.title.count).min() else { return nil }
        let closest = matches.filter { $0.title.count == shortest }
        return closest.count == 1 ? closest[0] : nil
    }

    /// Keyboard commands from the search field. Returns true when handled.
    func handle(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveDown(_:)):
            move(1)
        case #selector(NSResponder.insertBacktab(_:)), #selector(NSResponder.moveUp(_:)):
            move(-1)
        case #selector(NSResponder.insertNewline(_:)):
            confirm()
        case #selector(NSResponder.cancelOperation(_:)):
            // Like Spotlight: first Esc clears the query, second one closes.
            if query.isEmpty { onCancel() } else { query = "" }
        default:
            return false
        }
        return true
    }

    private func refilter() {
        let terms = query.split(whereSeparator: \.isWhitespace).map { Array($0) }
        if terms.isEmpty {
            firstAppIndex = nil
            results = items.map { Result($0) }
            // The window you were in before this one. Not knowing it yet (just after launch), if the top window is the
            // one you're already in, default to the one below it. It isn't when, say, the desktop has focus or a
            // floating window from another app sits on top.
            selection = items.firstIndex(where: \.isPrevious) ?? (items.count > 1 && items[0].pid == currentAppPID ? 1 : 0)
        } else {
            // Equal scores keep windows in stacking order. A browser's tabs go where its front window is,
            // the ones their windows show first.
            var found: [(score: Int, order: [Int], result: Result, isOtherTab: Bool)] = []
            for (index, item) in items.enumerated() {
                // Rows for windows whose tabs are listed, and an app row once any are. Others, like Safari's
                // Settings window, stay.
                if let windows = tabWindows[item.pid], !windows.isEmpty,
                   item.element == nil || windows.contains(where: { BrowserTabs.windowTitle(item.title, matches: $0) }) {
                    continue
                }
                let title = Array(item.displayTitle)
                guard let match = Self.match(terms, in: title + [" "] + Array(item.appName)) else { continue }
                var result = Result(item)
                result.titleHits = match.hits.filter { $0 < title.count }
                if item.element != nil { // an app row's title is the app name already
                    result.subtitleHits = Set(match.hits.filter { $0 > title.count }.map { $0 - title.count - 1 })
                }
                found.append((match.score, [index], result, false))
            }
            for (pid, browserTabs) in tabs {
                let place = items.firstIndex { $0.pid == pid } ?? items.count
                for tab in browserTabs {
                    guard let match = Self.match(terms, in: tab) else { continue }
                    var result = Result(tab)
                    result.titleHits = match.titleHits
                    result.subtitleHits = match.subtitleHits
                    let order = [place, Int(pid), tab.isActive ? 0 : 1, tab.windowOrder, tab.index]
                    found.append((match.score, order, result, !tab.isActive))
                }
            }
            found.sort { $0.score != $1.score ? $0.score > $1.score : $0.order.lexicographicallyPrecedes($1.order) }
            var listed: [Result] = []
            var otherTabs = 0
            for entry in found {
                if entry.isOtherTab {
                    otherTabs += 1
                    if otherTabs > Self.maxOtherTabs { continue }
                }
                listed.append(entry.result)
            }

            var matchedApps: [(score: Int, index: Int, app: InstalledApp, hits: Set<Int>)] = []
            for (index, app) in apps.enumerated() {
                guard let match = Self.match(terms, in: app.searchText) else { continue }
                matchedApps.append((match.score, index, app, match.hits))
            }
            matchedApps.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                // "Notes" before "Notes Helper"; `apps` is in alphabetical order after that.
                if $0.app.name.count != $1.app.name.count { return $0.app.name.count < $1.app.name.count }
                return $0.index < $1.index
            }
            let appResults = matchedApps.prefix(Self.maxApps).map { entry in
                var result = Result(entry.app)
                result.titleHits = entry.hits.filter { $0 < entry.app.name.count }
                return result
            }

            firstAppIndex = appResults.isEmpty ? nil : listed.count
            results = listed + appResults
            selection = 0
        }
        onHeightChange(height)
    }

    /// Every term has to match somewhere in `text`. Adds up their scores and collects the matched positions.
    private static func match(_ terms: [[Character]], in text: [Character]) -> (score: Int, hits: Set<Int>)? {
        var score = 0
        var hits = Set<Int>()
        for term in terms {
            guard let match = Fuzzy.match(term, in: text) else { return nil }
            score += match.score
            hits.formUnion(match.positions)
        }
        return (score, hits)
    }

    /// Like `match`, but a term can also appear unbroken in the tab's address. Matches in the browser name or
    /// the domain are marked on the second line ("domain · Browser").
    private static func match(_ terms: [[Character]], in tab: BrowserTab)
        -> (score: Int, titleHits: Set<Int>, subtitleHits: Set<Int>)? {
        let titleLength = tab.title.count
        let domainLength = tab.domain.count
        var score = 0
        var titleHits = Set<Int>(), subtitleHits = Set<Int>()
        for term in terms {
            let name = Fuzzy.match(term, in: tab.nameText)
            let address = Fuzzy.substringMatch(term, in: tab.addressText) { !(tab.topLevelDomain?.contains($0) ?? false) }
            if let name, name.score >= address?.score ?? Int.min {
                score += name.score
                for position in name.positions {
                    if position < titleLength {
                        titleHits.insert(position)
                    } else if position > titleLength {
                        subtitleHits.insert(position - titleLength - 1 + tab.browserNameOffset)
                    }
                }
            } else if let address {
                score += address.score
                subtitleHits.formUnion(address.positions.filter { $0 < domainLength })
            } else {
                return nil
            }
        }
        return (score, titleHits, subtitleHits)
    }
}

// MARK: Panel

final class SwitcherPanel: NSPanel {
    init(model: SwitcherModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.searchHeight)
                .insetBy(dx: -Layout.shadowMargin, dy: -Layout.shadowMargin),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // The system shadow traces the window's alpha and adds a dark rim that doesn't follow
        // the glass edge; CardContainerView draws a soft one instead.
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: SwitcherView(model: model))
        hosting.sizingOptions = []
        let container = CardContainerView(card: Self.background(containing: hosting))
        container.onClickOutsideCard = { [weak self] in self?.orderOut(nil) }
        contentView = container
    }

    private static func background(containing content: NSView) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Layout.cornerRadius
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: Layout.cornerRadius)
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        return effect
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    override var canBecomeKey: Bool { true }

    /// Puts the caret in the search field before the panel appears. Doing it a frame or two after
    /// made the placeholder visibly redraw on every open. An editing session that's still going from
    /// last time is left alone, since restarting it causes the same redraw.
    func focusSearchField() {
        contentView?.layoutSubtreeIfNeeded() // lets SwiftUI create the field on the first open
        guard let field = contentView?.firstDescendant(ofType: SearchTextField.self), field.currentEditor() == nil else { return }
        makeFirstResponder(field)
    }

    /// Positions the window so the card itself (not the shadow margin) lands on `cardFrame`.
    func setCardFrame(_ cardFrame: NSRect) {
        setFrame(cardFrame.insetBy(dx: -Layout.shadowMargin, dy: -Layout.shadowMargin), display: true)
    }

    // Clicking anywhere else dismisses it, like Spotlight.
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    // There's no main menu in an agent app, so wire up the usual text editing shortcuts here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers {
            let action: Selector? = switch key {
            case "a": #selector(NSText.selectAll(_:))
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "x": #selector(NSText.cut(_:))
            case "z": Selector(("undo:"))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Holds the glass card inset by `Layout.shadowMargin` and draws a soft drop shadow around it.
/// The shadow is cut out underneath the card so the translucent glass doesn't pick it up and look muddy.
private final class CardContainerView: NSView {
    private let card: NSView
    private let shadowView = ShadowView()
    var onClickOutsideCard: () -> Void = {}

    init(card: NSView) {
        self.card = card
        super.init(frame: .zero)
        addSubview(shadowView)
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let cardRect = bounds.insetBy(dx: Layout.shadowMargin, dy: Layout.shadowMargin)
        // insetBy returns an infinite null rect when the window is smaller than the margins.
        guard cardRect.width >= Layout.cornerRadius * 2, cardRect.height >= Layout.cornerRadius * 2 else { return }
        card.frame = cardRect
        shadowView.frame = bounds
        shadowView.update(cardRect: cardRect)
    }

    // Only the margin around the card reaches this view.
    override func mouseDown(with event: NSEvent) {
        onClickOutsideCard()
    }

    private final class ShadowView: NSView {
        private let mask = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.22
            layer?.shadowRadius = 22
            layer?.shadowOffset = CGSize(width: 0, height: -10)
            mask.fillRule = .evenOdd
            layer?.mask = mask
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func update(cardRect: NSRect) {
            let card = CGPath(roundedRect: cardRect, cornerWidth: Layout.cornerRadius,
                              cornerHeight: Layout.cornerRadius, transform: nil)
            let outsideCard = CGMutablePath()
            outsideCard.addRect(bounds)
            outsideCard.addPath(card)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.shadowPath = card
            mask.frame = bounds
            mask.path = outsideCard
            CATransaction.commit()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}

// MARK: Views

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                SearchField(text: $model.query, onCommand: model.handle)
                    .overlay(alignment: .leading) {
                        // Drawn by SwiftUI rather than the field: it adapts to whatever is behind the glass, like
                        // the rows. The field's own placeholder can't, since vibrancy is off there (see SearchTextField).
                        if model.query.isEmpty {
                            Text("Switch to window")
                                .font(.system(size: 24))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 2) // where the field starts its text
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(.horizontal, 20)
            .frame(height: Layout.searchHeight)

            if model.needsAccessibility {
                separator
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 18))
                        .foregroundStyle(.orange)
                        .frame(width: 30)
                    Text("Allow Accessibility access to see window titles")
                        .font(.system(size: 13))
                    Spacer(minLength: 8)
                    Button("Allow…") { model.requestAccessibility() }
                }
                .padding(.horizontal, Layout.listPadding + 10)
                .frame(height: Layout.rowHeight)
            }

            if !model.results.isEmpty {
                separator
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                                // The title goes with the first app's row, so scrolling to that row shows it too.
                                VStack(spacing: 0) {
                                    if index == model.firstAppIndex {
                                        sectionTitle("Applications")
                                    }
                                    ResultRow(result: result, isSelected: index == model.selection)
                                        .onTapGesture {
                                            model.selection = index
                                            model.confirm()
                                        }
                                }
                            }
                        }
                        .padding(Layout.listPadding)
                    }
                    .scrollIndicators(.never)
                    .id(model.showCount) // start scrolled to the top on every show
                    .onChange(of: model.selection) { _, selection in
                        guard model.results.indices.contains(selection) else { return }
                        proxy.scrollTo(model.results[selection].id)
                    }
                }
            } else if !model.query.isEmpty {
                separator
                Text(model.hasTabs ? "No matching windows, tabs or apps" : "No matching windows or apps")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: Layout.rowHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Layout.sectionTitleHeight, alignment: .bottom)
    }
}

struct ResultRow: View {
    let result: SwitcherModel.Result
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: result.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(result.title, hits: result.titleHits, size: 14))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(highlighted(result.subtitle, hits: result.subtitleHits, size: 11))
                    .lineLimit(1)
                    .opacity(isSelected ? 0.85 : 0.55)
            }
            Spacer(minLength: 8)
            if let badge = result.badge {
                Text(badge)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.primary.opacity(isSelected ? 0.2 : 0.08)))
                    .opacity(isSelected ? 0.9 : 0.6)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Layout.rowHeight)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// Bolds the characters the query matched.
    private func highlighted(_ text: String, hits: Set<Int>, size: CGFloat) -> AttributedString {
        var output = AttributedString()
        var run = ""
        var runIsHit = false
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            piece.font = .system(size: size, weight: runIsHit ? .bold : .regular)
            output += piece
            run = ""
        }
        for (index, character) in text.enumerated() {
            let isHit = hits.contains(index)
            if isHit != runIsHit { flush(); runIsHit = isHit }
            run.append(character)
        }
        flush()
        return output
    }
}

/// The panel's search box. A subclass so the panel can find it to focus it. Vibrancy is off because the
/// field's vibrant drawing switched back and forth several times as the glass appeared, which flickered.
/// The placeholder is drawn by SwitcherView instead, so it still adapts to the background.
final class SearchTextField: NSTextField {
    override var allowsVibrancy: Bool { false }
}

/// AppKit text field so we get Tab / arrows / Return / Esc as editing commands before the field eats them.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var onCommand: (Selector) -> Bool

    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .regular)
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: SearchTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField

        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            parent.onCommand(selector)
        }
    }
}
