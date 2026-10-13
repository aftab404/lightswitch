import Carbon.HIToolbox

/// A system-wide hotkey via Carbon's RegisterEventHotKey (needs no special permissions).
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x4C54_5357), id: 1) // 'LTSW'
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("Lightswitch: could not register hotkey (status \(status))")
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Whether one of macOS's own shortcuts (such as Spotlight's ⌘Space) is enabled on this key combination.
    /// Those win over app hotkeys, so ours would silently never fire.
    static func isTakenBySystem(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var hotKeys: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&hotKeys) == noErr,
              let entries = hotKeys?.takeRetainedValue() as? [[String: Any]] else { return false }
        return entries.contains { entry in
            (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (entry[kHISymbolicHotKeyCode as String] as? Int) == Int(keyCode)
                && (entry[kHISymbolicHotKeyModifiers as String] as? Int) == Int(modifiers)
        }
    }
}
