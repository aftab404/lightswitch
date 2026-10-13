import AppKit
import Carbon.HIToolbox

/// A key combination for the global shortcut. Modifiers are Carbon flags (cmdKey, optionKey…), the form
/// RegisterEventHotKey and macOS's list of its own shortcuts use.
struct Shortcut: Equatable, CustomStringConvertible {
    var keyCode: UInt32
    var modifiers: UInt32

    static let standard = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))

    /// In the order macOS shows them: ⌃⌥⇧⌘.
    private static let modifierKeys: [(flag: NSEvent.ModifierFlags, carbon: Int, symbol: String)] = [
        (.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘"),
    ]

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode), modifiers: Self.carbonModifiers(event.modifierFlags))
    }

    /// Drops Fn, Caps Lock and the like: arrow and function keys report Fn even when it isn't held.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        modifierKeys.reduce(0) { flags.contains($1.flag) ? $0 | UInt32($1.carbon) : $0 }
    }

    var modifierFlags: NSEvent.ModifierFlags {
        Self.modifierKeys.reduce([]) { modifiers & UInt32($1.carbon) != 0 ? $0.union($1.flag) : $0 }
    }

    /// Shift alone doesn't count: it would take capitals and symbols away from typing.
    var hasModifier: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        modifierKeys.filter { flags.contains($0.flag) }.map(\.symbol).joined()
    }

    /// Like “⌥⌘Space”.
    var description: String {
        let key = Self.specialKeys[Int(keyCode)]?.name ?? Self.character(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
        return Self.symbols(for: modifierFlags) + key
    }

    /// For NSMenuItem.keyEquivalent, together with `modifierFlags`.
    var keyEquivalent: String {
        Self.specialKeys[Int(keyCode)]?.keyEquivalent ?? Self.character(for: keyCode) ?? ""
    }

    var isTakenBySystem: Bool {
        HotKey.isTakenBySystem(keyCode: keyCode, modifiers: modifiers)
    }

    // MARK: Key names

    private static let specialKeys: [Int: (name: String, keyEquivalent: String)] = {
        func key(_ character: Int) -> String { String(utf16CodeUnits: [unichar(character)], count: 1) }
        var keys: [Int: (name: String, keyEquivalent: String)] = [
            kVK_Space: ("Space", " "),
            kVK_Return: ("↩", "\r"),
            kVK_ANSI_KeypadEnter: ("⌤", "\u{3}"),
            kVK_Tab: ("⇥", "\t"),
            kVK_Delete: ("⌫", "\u{8}"),
            kVK_ForwardDelete: ("⌦", key(NSDeleteFunctionKey)),
            kVK_Escape: ("⎋", "\u{1b}"),
            kVK_LeftArrow: ("←", key(NSLeftArrowFunctionKey)),
            kVK_RightArrow: ("→", key(NSRightArrowFunctionKey)),
            kVK_UpArrow: ("↑", key(NSUpArrowFunctionKey)),
            kVK_DownArrow: ("↓", key(NSDownArrowFunctionKey)),
            kVK_Home: ("↖", key(NSHomeFunctionKey)),
            kVK_End: ("↘", key(NSEndFunctionKey)),
            kVK_PageUp: ("⇞", key(NSPageUpFunctionKey)),
            kVK_PageDown: ("⇟", key(NSPageDownFunctionKey)),
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in functionKeys.enumerated() {
            keys[code] = ("F\(index + 1)", key(NSF1FunctionKey + index))
        }
        return keys
    }()

    /// What the key types without modifiers in the current keyboard layout (an ASCII-capable one, as menus use).
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { bytes in
            UCKeyTranslate(bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(keyCode), UInt16(kUCKeyActionDisplay),
                           0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                           &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let character = String(utf16CodeUnits: characters, count: length)
        return character.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty ? nil : character
    }

    // MARK: Saving

    private static let keyCodeKey = "shortcutKeyCode"
    private static let modifiersKey = "shortcutModifiers"

    /// The shortcut chosen with Change Shortcut…, or ⌘Space.
    static var saved: Shortcut {
        let defaults = UserDefaults.standard
        guard let keyCode = (defaults.object(forKey: keyCodeKey) as? Int).flatMap({ UInt32(exactly: $0) }),
              let modifiers = (defaults.object(forKey: modifiersKey) as? Int).flatMap({ UInt32(exactly: $0) }) else { return .standard }
        let shortcut = Shortcut(keyCode: keyCode, modifiers: modifiers)
        return shortcut.hasModifier ? shortcut : .standard
    }

    func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: Self.keyCodeKey)
        UserDefaults.standard.set(Int(modifiers), forKey: Self.modifiersKey)
    }
}

// MARK: macOS's own shortcuts

extension Shortcut {
    private struct SystemShortcut {
        let id: Int // its key in com.apple.symbolichotkeys
        let section: String // in System Settings → Keyboard → Keyboard Shortcuts
        let name: String
        let standard: Shortcut
    }

    /// The ones a switcher shortcut is likely to run into.
    private static let systemShortcuts = [
        SystemShortcut(id: 64, section: "Spotlight", name: "Show Spotlight search", standard: Shortcut(kVK_Space, cmdKey)),
        SystemShortcut(id: 65, section: "Spotlight", name: "Show Finder search window", standard: Shortcut(kVK_Space, cmdKey | optionKey)),
        SystemShortcut(id: 60, section: "Input Sources", name: "Select the previous input source", standard: Shortcut(kVK_Space, controlKey)),
        SystemShortcut(id: 61, section: "Input Sources", name: "Select next source in Input menu", standard: Shortcut(kVK_Space, controlKey | optionKey)),
        SystemShortcut(id: 32, section: "Mission Control", name: "Mission Control", standard: Shortcut(kVK_UpArrow, controlKey)),
        SystemShortcut(id: 33, section: "Mission Control", name: "Application windows", standard: Shortcut(kVK_DownArrow, controlKey)),
        SystemShortcut(id: 79, section: "Mission Control", name: "Move left a space", standard: Shortcut(kVK_LeftArrow, controlKey)),
        SystemShortcut(id: 81, section: "Mission Control", name: "Move right a space", standard: Shortcut(kVK_RightArrow, controlKey)),
        SystemShortcut(id: 28, section: "Screenshots", name: "Save picture of screen as a file", standard: Shortcut(kVK_ANSI_3, cmdKey | shiftKey)),
        SystemShortcut(id: 29, section: "Screenshots", name: "Copy picture of screen to the clipboard", standard: Shortcut(kVK_ANSI_3, cmdKey | shiftKey | controlKey)),
        SystemShortcut(id: 30, section: "Screenshots", name: "Save picture of selected area as a file", standard: Shortcut(kVK_ANSI_4, cmdKey | shiftKey)),
        SystemShortcut(id: 31, section: "Screenshots", name: "Copy picture of selected area to the clipboard", standard: Shortcut(kVK_ANSI_4, cmdKey | shiftKey | controlKey)),
        SystemShortcut(id: 184, section: "Screenshots", name: "Screenshot and recording options", standard: Shortcut(kVK_ANSI_5, cmdKey | shiftKey)),
    ]

    private init(_ keyCode: Int, _ modifiers: Int) {
        self.init(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }

    /// Which macOS feature has this combination, as its Keyboard Shortcuts section and the shortcut's name there.
    /// Nil if it isn't one of the common ones.
    var systemOwner: (section: String, name: String)? {
        let saved = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        let owner = Self.systemShortcuts.first { known in
            let entry = saved[String(known.id)] as? [String: Any]
            guard entry?["enabled"] as? Bool ?? true else { return false }
            // Only shortcuts changed from their default are saved, with NSEvent-style modifiers.
            guard let parameters = (entry?["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3 else {
                return known.standard == self
            }
            let flags = NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: parameters[2]))
            return Shortcut(keyCode: UInt32(truncatingIfNeeded: parameters[1]), modifiers: Self.carbonModifiers(flags)) == self
        }
        return owner.map { ($0.section, $0.name) }
    }
}
