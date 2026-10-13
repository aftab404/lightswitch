import AppKit
import Carbon.HIToolbox

/// A small window that records the next key combination as the global shortcut. Esc cancels.
@MainActor
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    private static let hint = "Press the new shortcut, with ⌘, ⌥ or ⌃. Esc cancels."

    /// Tries a recorded shortcut. Returns why it can't be used, or nil once it's in use.
    var onRecord: (Shortcut) -> String? = { _ in nil }

    private let window = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 340, height: 160),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: true
    )
    private let keysLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let resetButton = NSButton(title: "Reset to \(Shortcut.standard)", target: nil, action: nil)
    private var current = Shortcut.standard
    private var monitor: Any?
    private var previousApp: NSRunningApplication?

    var isVisible: Bool { window.isVisible }

    override init() {
        super.init()
        window.title = "Lightswitch Shortcut"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self

        keysLabel.font = .systemFont(ofSize: 26, weight: .medium)
        keysLabel.translatesAutoresizingMaskIntoConstraints = false
        let keysBox = NSBox()
        keysBox.boxType = .custom
        keysBox.cornerRadius = 10
        keysBox.borderColor = .separatorColor
        keysBox.fillColor = .quaternarySystemFill
        keysBox.contentViewMargins = .zero
        keysBox.contentView?.addSubview(keysLabel)

        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.alignment = .center

        resetButton.target = self
        resetButton.action = #selector(resetToStandard)
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let buttons = NSStackView(views: [resetButton, cancelButton])

        let stack = NSStackView(views: [keysBox, messageLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        NSLayoutConstraint.activate([
            keysBox.widthAnchor.constraint(equalToConstant: 300),
            keysBox.heightAnchor.constraint(equalToConstant: 56),
            keysLabel.centerXAnchor.constraint(equalTo: keysBox.centerXAnchor),
            keysLabel.centerYAnchor.constraint(equalTo: keysBox.centerYAnchor),
            messageLabel.widthAnchor.constraint(equalToConstant: 300),
        ])
        window.contentView = stack
    }

    func show(current: Shortcut) {
        self.current = current
        keysLabel.stringValue = current.description
        resetButton.isHidden = current == .standard
        setMessage(Self.hint, isError: false)
        if !window.isVisible {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApp = frontmost == .current ? nil : frontmost
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return used ? nil : event
            }
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Sees keys before the window does, so Tab, Return and ⌘-combinations are recorded rather than acted on.
    /// Returns whether it used the event.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        if event.type == .flagsChanged {
            let held = Shortcut.symbols(for: event.modifierFlags)
            keysLabel.stringValue = held.isEmpty ? current.description : held
            return false
        }
        guard !event.isARepeat else { return true }
        let shortcut = Shortcut(event: event)
        if shortcut == Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0) {
            window.close()
        } else if !shortcut.hasModifier {
            keysLabel.stringValue = shortcut.description
            setMessage("Add ⌘, ⌥ or ⌃, so the shortcut doesn't get in the way of typing.", isError: true)
        } else {
            record(shortcut)
        }
        return true
    }

    private func record(_ shortcut: Shortcut) {
        keysLabel.stringValue = shortcut.description
        if let problem = onRecord(shortcut) {
            setMessage(problem, isError: true)
        } else {
            window.close()
        }
    }

    private func setMessage(_ message: String, isError: Bool) {
        messageLabel.stringValue = message
        messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        // Fit the message, keeping the title bar where it is.
        guard let content = window.contentView else { return }
        var frame = window.frame
        let height = window.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize)).height
        frame.origin.y += frame.height - height
        frame.size.height = height
        window.setFrame(frame, display: true)
    }

    @objc private func resetToStandard() {
        record(.standard)
    }

    @objc private func cancel() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        // An agent app doesn't hand focus back by itself when its last window closes.
        if NSApp.isActive { previousApp?.activate() }
        previousApp = nil
    }
}
