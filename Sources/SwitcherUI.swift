import AppKit
import SwiftUI

enum Layout {
    static let width: CGFloat = 680
    static let searchHeight: CGFloat = 56
    static let rowHeight: CGFloat = 46
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
        let item: WindowItem
        let titleHits: Set<Int>
        let appHits: Set<Int>
        var id: String { item.id }
    }

    @Published var query = "" {
        didSet { if query != oldValue { refilter() } }
    }
    @Published private(set) var results: [Result] = []
    @Published var selection = 0
    @Published private(set) var showCount = 0
    /// Without Accessibility access macOS hides window titles, so only app rows can be listed.
    @Published private(set) var needsAccessibility = false

    var items: [WindowItem] = [] {
        didSet { refilter() }
    }

    var onConfirm: (WindowItem) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }

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
        } else if !query.isEmpty {
            height += 1 + Layout.rowHeight
        }
        return height
    }

    func prepareForShow(currentApp: pid_t?) {
        currentAppPID = currentApp
        needsAccessibility = !Accessibility.isTrusted
        query = ""
        items = []
        showCount += 1
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
        onConfirm(results[selection].item)
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
            results = items.map { Result(item: $0, titleHits: [], appHits: []) }
            // If the top window is the one you're already in, default to the one before it. It isn't when,
            // say, the desktop has focus or a floating window from another app sits on top.
            selection = results.count > 1 && results[0].item.pid == currentAppPID ? 1 : 0
        } else {
            var scored: [(score: Int, index: Int, result: Result)] = []
            for (index, item) in items.enumerated() {
                let title = Array(item.displayTitle)
                let haystack = title + [" "] + Array(item.appName)
                var total = 0
                var hits = Set<Int>()
                var matchedAll = true
                for term in terms {
                    guard let match = Fuzzy.match(term, in: haystack) else { matchedAll = false; break }
                    total += match.score
                    hits.formUnion(match.positions)
                }
                guard matchedAll else { continue }
                let result = Result(
                    item: item,
                    titleHits: hits.filter { $0 < title.count },
                    appHits: Set(hits.filter { $0 > title.count }.map { $0 - title.count - 1 })
                )
                scored.append((total, index, result))
            }
            scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            results = scored.map(\.result)
            selection = 0
        }
        onHeightChange(height)
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

// MARK: Views

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                SearchField(text: $model.query, focusToken: model.showCount, onCommand: model.handle)
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
                                ResultRow(result: result, isSelected: index == model.selection)
                                    .onTapGesture {
                                        model.selection = index
                                        model.confirm()
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
                Text("No matching windows")
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
}

struct ResultRow: View {
    let result: SwitcherModel.Result
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: result.item.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(result.item.displayTitle, hits: result.titleHits, size: 14))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(highlighted(result.item.appName, hits: result.item.element == nil ? [] : result.appHits, size: 11))
                    .lineLimit(1)
                    .opacity(isSelected ? 0.85 : 0.55)
            }
            Spacer(minLength: 8)
            if let badge = result.item.badge {
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

/// AppKit text field so we get Tab / arrows / Return / Esc as editing commands before the field eats them.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    var onCommand: (Selector) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .regular)
        field.placeholderString = "Switch to window"
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        var focusToken = -1

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
