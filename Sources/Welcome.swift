import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The setup window. It's shown on first launch, again whenever Lightswitch starts without Accessibility access
/// (macOS asks afresh after every update of an app that isn't notarized), and from the menu. It takes the place of
/// the separate prompts and alerts a new user used to get, and shows live which steps are done.
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    private static let completedKey = "welcomeCompleted"

    let model = WelcomeModel()
    private var window: NSWindow?
    private var poll: Timer?
    private var previousApp: NSRunningApplication?

    var isVisible: Bool { window?.isVisible ?? false }

    /// On first launch, and whenever Lightswitch starts without Accessibility access, which it can't list windows without.
    var isNeededAtLaunch: Bool {
        !UserDefaults.standard.bool(forKey: Self.completedKey) || !Accessibility.isTrusted
    }

    override init() {
        super.init()
        model.onDone = { [weak self] in self?.window?.close() }
        model.onStepDoneElsewhere = { [weak self] in self?.bringBack() }
    }

    func show() {
        if !isVisible {
            let completed = UserDefaults.standard.bool(forKey: Self.completedKey)
            model.prepareForShow(greeting: !completed ? .firstRun : Accessibility.isTrusted ? .setup : .welcomeBack)
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApp = frontmost == .current ? nil : frontmost
            if window == nil {
                window = makeWindow()
                window?.center()
            }
            // Permissions and shortcuts change in System Settings, which tells nobody.
            poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.refresh() }
            }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // At login macOS may not let Lightswitch activate, which would leave the window behind the user's.
        window?.orderFrontRegardless()
    }

    /// Re-reads the shortcut right away, after it was changed from elsewhere.
    func refresh() {
        guard isVisible else { return }
        model.refresh(announcing: false)
    }

    func switcherDidOpen() {
        guard isVisible else { return }
        model.switcherDidOpen()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Welcome to Lightswitch"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = .moveToActiveSpace
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.delegate = self
        let content = NSHostingView(rootView: WelcomeView(model: model))
        window.contentView = content
        window.setContentSize(content.fittingSize)
        return window
    }

    /// Once the user has done a step in System Settings, so they see it ticked off and what's left.
    private func bringBack() {
        guard let window, window.isVisible, !NSApp.isActive else { return }
        NSApp.activate()
        window.orderFrontRegardless()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.checkBrowsers() // the user may have changed them in System Settings
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        poll?.invalidate()
        poll = nil
        // An agent app doesn't hand focus back by itself when its last window closes.
        if NSApp.isActive { previousApp?.activate() }
        previousApp = nil
    }
}

// MARK: Model

@MainActor
final class WelcomeModel: ObservableObject {
    enum Greeting { case firstRun, welcomeBack, setup }

    /// Whether Lightswitch may read a browser's tabs.
    enum Access {
        case checking, notAsked, asking, allowed, denied

        init(_ permission: BrowserTabs.Permission) {
            switch permission {
            case .allowed: self = .allowed
            case .denied: self = .denied
            case .notAsked, .unknown: self = .notAsked // asking will tell
            }
        }
    }

    struct BrowserRow: Identifiable {
        let browser: BrowserTabs.Browser
        var access: Access
        var id: pid_t { browser.pid }
    }

    /// The usual choice for keeping Spotlight on ⌘Space.
    static let alternative = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    @Published private(set) var greeting = Greeting.firstRun
    @Published private(set) var isTrusted = false
    @Published private(set) var hasAskedForAccessibility = false
    @Published private(set) var shortcut = Shortcut.standard
    /// Registered, and not one of macOS's own shortcuts, which would beat it.
    @Published private(set) var shortcutIsReady = false
    @Published private(set) var isShortcutTaken = false
    /// The macOS feature that has the shortcut, if it's one of the common ones.
    @Published private(set) var shortcutOwner: (section: String, name: String)?
    @Published private(set) var canUseAlternative = false
    @Published private(set) var shortcutProblem: String?
    /// The supported browsers that are running.
    @Published private(set) var browsers: [BrowserRow] = []
    @Published private(set) var hasOpenedSwitcher = false
    /// nil while Lightswitch isn't in an Applications folder, the only place it opens at login from.
    @Published private(set) var opensAtLogin: Bool?

    var currentShortcut: () -> Shortcut = { .saved }
    var isShortcutRegistered: () -> Bool = { false }
    /// Tries a shortcut. Returns why it can't be used, or nil once it's in use.
    var onUseShortcut: (Shortcut) -> String? = { _ in nil }
    var onChangeShortcut: () -> Void = {}
    var loginItemState: () -> Bool? = { nil }
    var onSetOpensAtLogin: (Bool) -> Void = { _ in }
    var onDone: () -> Void = {}
    /// When Accessibility or the shortcut becomes ready while Lightswitch isn't the active app.
    var onStepDoneElsewhere: () -> Void = {}

    /// Browsers with a permission check in flight.
    private var checking: Set<pid_t> = []

    /// The first of the steps Lightswitch can't do without that's still to do. Its button is the prominent one.
    var nextStep: Int? { !isTrusted ? 1 : !shortcutIsReady ? 2 : nil }
    var browsersAreDone: Bool { !browsers.isEmpty && browsers.allSatisfy { $0.access == .allowed } }
    var isAsking: Bool { browsers.contains { $0.access == .asking } }

    func prepareForShow(greeting: Greeting) {
        self.greeting = greeting
        hasAskedForAccessibility = false
        hasOpenedSwitcher = false
        shortcutProblem = nil
        opensAtLogin = loginItemState()
        refresh(announcing: false)
        checkBrowsers()
    }

    /// Reads what may have changed outside the window. Called every second while it's open.
    func refresh(announcing: Bool = true) {
        let wasTrusted = isTrusted, wasReady = shortcutIsReady
        isTrusted = Accessibility.isTrusted
        shortcut = currentShortcut()
        isShortcutTaken = shortcut.isTakenBySystem
        shortcutOwner = isShortcutTaken ? shortcut.systemOwner : nil
        shortcutIsReady = !isShortcutTaken && isShortcutRegistered()
        canUseAlternative = shortcut != Self.alternative && !Self.alternative.isTakenBySystem
        if shortcutIsReady { shortcutProblem = nil }
        updateBrowserList()
        if announcing && ((isTrusted && !wasTrusted) || (shortcutIsReady && !wasReady)) {
            onStepDoneElsewhere()
        }
    }

    func switcherDidOpen() {
        hasOpenedSwitcher = true
    }

    // MARK: Actions

    func requestAccessibility() {
        hasAskedForAccessibility = true
        Accessibility.requestAgain()
    }

    func useAlternative() {
        shortcutProblem = onUseShortcut(Self.alternative)
        refresh(announcing: false)
    }

    func changeShortcut() {
        onChangeShortcut()
    }

    func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    /// Shows macOS's prompt for letting Lightswitch control the browser.
    func ask(_ pid: pid_t) {
        setAccess(.asking, of: pid)
        BrowserTabs.permission(of: pid, ask: true) { [weak self] permission in
            self?.setAccess(Access(permission), of: pid)
        }
    }

    func setOpensAtLogin(_ on: Bool) {
        onSetOpensAtLogin(on)
        opensAtLogin = loginItemState()
    }

    func done() {
        onDone()
    }

    // MARK: Browsers

    /// Checks every listed browser again, without prompting.
    func checkBrowsers() {
        updateBrowserList()
        for row in browsers where row.access != .asking { check(row.id) }
    }

    private func updateBrowserList() {
        let running = BrowserTabs.running
        guard running.map(\.pid) != browsers.map(\.id) else { return }
        browsers = running.map { browser in
            browsers.first { $0.id == browser.pid } ?? BrowserRow(browser: browser, access: .checking)
        }
        for row in browsers where row.access == .checking { check(row.id) }
    }

    private func check(_ pid: pid_t) {
        guard checking.insert(pid).inserted else { return }
        BrowserTabs.permission(of: pid, ask: false) { [weak self] permission in
            guard let self else { return }
            self.checking.remove(pid)
            // A check that started before the user clicked Allow… mustn't hide the prompt's progress.
            guard self.browsers.first(where: { $0.id == pid })?.access != .asking else { return }
            self.setAccess(Access(permission), of: pid)
        }
    }

    private func setAccess(_ access: Access, of pid: pid_t) {
        guard let index = browsers.firstIndex(where: { $0.id == pid }) else { return }
        browsers[index].access = access
    }

    // MARK: Text

    var title: String {
        switch greeting {
        case .firstRun: "Welcome to Lightswitch"
        case .welcomeBack: "Welcome back"
        case .setup: "Lightswitch Setup"
        }
    }

    var subtitle: String {
        switch greeting {
        case .firstRun: "A few quick steps, then \(shortcut) takes you to any window, tab or app."
        case .welcomeBack: "Lightswitch can't read window titles right now. macOS asks again after every update, so allow Accessibility access below."
        case .setup: "What Lightswitch may do, and the shortcut that opens it."
        }
    }

    var accessibilityDetail: String {
        isTrusted
            ? "Allowed. Lightswitch can read window titles and bring the window you pick to the front."
            : "macOS only lets apps read window titles and bring a window to the front through Accessibility. Lightswitch uses it for exactly that."
    }

    var shortcutDetail: String {
        if shortcutIsReady { return "Press it anywhere to open Lightswitch." }
        guard isShortcutTaken else { return "macOS wouldn't register it, so another app may be using it. Choose another." }
        guard let owner = shortcutOwner else {
            return "A macOS shortcut uses it, and macOS's own shortcuts come first. Choose another, or turn that one off "
                + "under Keyboard Shortcuts… in Keyboard Settings."
        }
        if owner.section == "Spotlight" {
            let keep = canUseAlternative ? "use \(Self.alternative)" : "choose another shortcut"
            return "Spotlight has it, and macOS's own shortcuts come first. Keep Spotlight and \(keep), or, since Lightswitch "
                + "opens apps too, untick “\(owner.name)” in Keyboard Settings → Keyboard Shortcuts… → Spotlight."
        }
        return "\(owner.section) uses it for “\(owner.name)”, and macOS's own shortcuts come first. Choose another, or turn "
            + "that off in Keyboard Settings → Keyboard Shortcuts… → \(owner.section)."
    }

    var browsersDetail: String {
        browsers.isEmpty
            ? "Lightswitch can search the tabs of Chrome, Safari, Brave, Arc, Edge, Vivaldi and Chromium. None is running right now; "
                + "the first time you open Lightswitch with one running, macOS asks whether it may read its tabs."
            : "Search the tabs open in your browsers, too. macOS asks once for each browser."
    }
}

// MARK: Views

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 30) // below the transparent title bar
                .padding(.bottom, 20)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                accessibilityStep
                Divider().padding(.leading, 38)
                shortcutStep
                Divider().padding(.leading, 38)
                browsersStep
                Divider().padding(.leading, 38)
                tryStep
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 4)
            Divider()
            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title)
                    .font(.system(size: 22, weight: .semibold))
                Text(model.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accessibilityStep: some View {
        Step(number: 1, title: "Allow Accessibility access", isDone: model.isTrusted) {
            Detail(model.accessibilityDetail)
            if !model.isTrusted {
                HStack(spacing: 10) {
                    Button("Allow Access…") { model.requestAccessibility() }
                        .prominent(model.nextStep == 1)
                    if model.hasAskedForAccessibility {
                        Text("Then switch on Lightswitch in System Settings.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var shortcutStep: some View {
        Step(number: 2, title: "Your shortcut", isDone: model.shortcutIsReady, accessory: { Keys(model.shortcut) }) {
            Detail(model.shortcutDetail)
            if model.shortcutIsReady {
                Button("Change Shortcut…") { model.changeShortcut() }
                    .controlSize(.small)
                    .padding(.top, 2)
            } else {
                HStack(spacing: 8) {
                    if model.canUseAlternative {
                        Button("Use \(WelcomeModel.alternative.description)") { model.useAlternative() }
                            .prominent(model.nextStep == 2)
                    }
                    Button("Choose Another…") { model.changeShortcut() }
                    if model.isShortcutTaken {
                        Button("Open Keyboard Settings") { model.openKeyboardSettings() }
                    }
                }
                .padding(.top, 2)
                if let problem = model.shortcutProblem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var browsersStep: some View {
        Step(number: 3, title: "Browser tabs", isOptional: true, isDone: model.browsersAreDone) {
            Detail(model.browsersDetail)
            if !model.browsers.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.browsers) { row in
                        BrowserRowView(row: row, model: model)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var tryStep: some View {
        Step(number: 4, title: "Try it", isDone: model.hasOpenedSwitcher) {
            let keys = Text(model.shortcut.description).fontWeight(.semibold).foregroundStyle(.primary)
            if model.hasOpenedSwitcher {
                Detail("That's it. Tab or the arrow keys pick a row, Return takes you there and Esc closes the panel.")
            } else if model.shortcutIsReady {
                Text("Press \(keys) anywhere and type a few letters of a window, tab or app.")
                    .detailStyle()
            } else {
                Text("Once your shortcut works, press it anywhere and type a few letters of a window, tab or app.")
                    .detailStyle()
            }
        }
    }

    private var footer: some View {
        HStack {
            if let opensAtLogin = model.opensAtLogin {
                Toggle("Launch Lightswitch at login", isOn: Binding(get: { opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                    .toggleStyle(.checkbox)
            } else {
                Text("Move Lightswitch to Applications so it can launch at login.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            // Return only closes the window once Lightswitch has what it needs.
            Button("Done") { model.done() }
                .keyboardShortcut(model.nextStep == nil ? .defaultAction : nil)
        }
    }
}

/// A numbered step that turns into a check mark once it's done.
private struct Step<Accessory: View, Content: View>: View {
    let number: Int
    let title: String
    var isOptional = false
    let isDone: Bool
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(number: Int, title: String, isOptional: Bool = false, isDone: Bool,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.number = number
        self.title = title
        self.isOptional = isOptional
        self.isDone = isDone
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                if isDone {
                    Circle().fill(Color.green)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
                    Text("\(number)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    accessory()
                    if isOptional {
                        Text("Optional")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.primary.opacity(0.08)))
                    }
                }
                .frame(minHeight: 24)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
    }
}

private extension View {
    @ViewBuilder
    func prominent(_ isProminent: Bool) -> some View {
        if isProminent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

private struct Detail: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).detailStyle()
    }
}

private extension Text {
    func detailStyle() -> some View {
        font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A shortcut drawn like keys, as in the shortcut recorder.
private struct Keys: View {
    let shortcut: Shortcut

    init(_ shortcut: Shortcut) {
        self.shortcut = shortcut
    }

    var body: some View {
        Text(shortcut.description)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: .quaternarySystemFill)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

private struct BrowserRowView: View {
    let row: WelcomeModel.BrowserRow
    @ObservedObject var model: WelcomeModel

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: row.browser.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
            Text(row.browser.name)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            switch row.access {
            case .checking:
                EmptyView()
            case .notAsked:
                Button("Allow…") { model.ask(row.id) }
                    .controlSize(.small)
                    .disabled(model.isAsking)
            case .asking:
                ProgressView().controlSize(.small)
                Text("Waiting for your answer")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            case .allowed:
                Label("Allowed", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            case .denied:
                Text("Not allowed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Open Settings…") { model.openAutomationSettings() }
                    .controlSize(.small)
            }
        }
        .frame(minHeight: 22)
    }
}
