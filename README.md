<img src="icon/AppIcon-1024.png" width="128" alt="Lightswitch icon">

# Lightswitch

**[aftab404.github.io/lightswitch](https://aftab404.github.io/lightswitch/)**

![Lightswitch: type a few letters of a window's title and jump to it](media/lightswitch-demo.gif)

Spotlight-style fuzzy window switcher. Press ⌘Space and start typing a window title or app name. Tab / Shift-Tab (or ↑/↓, ⌃N/⌃P) move the selection, Return jumps to that window, and Esc clears the query or closes the panel.

## Download

**[Download Lightswitch.dmg](https://github.com/aftab404/lightswitch/releases/latest/download/Lightswitch.dmg)** (macOS 14 or later, Apple silicon and Intel). Open it and drag Lightswitch into Applications.

The app isn't notarized by Apple yet, so the first launch needs one extra confirmation:

1. Open Lightswitch. macOS says it was not opened because it can't verify the developer. Click **Done**.
2. Open System Settings → Privacy & Security and scroll down to the Security section.
3. Next to the message about Lightswitch, click **Open Anyway**, then confirm with your password or Touch ID.

You only do this once per version.

## Build from source

```bash
./build.sh install
```

This builds `build/Lightswitch.app`, copies it to `~/Applications`, and launches it. It needs the Xcode Command Line Tools (`xcode-select --install`). `./build.sh dmg` builds a universal app and packages it as `build/Lightswitch.dmg` for release. `demo/record.sh` records the demo above with sample windows (it needs Screen Recording permission) and writes `media/lightswitch-demo.mp4` and `.gif`.

Either way, the app runs as a menu bar item and registers itself as a login item on first launch. You can turn that off in the menu.

## One-time setup

1. **Accessibility:** System Settings → Privacy & Security → Accessibility → enable Lightswitch. It needs this to read window titles and raise windows.
2. **Free up ⌘Space:** System Settings → Keyboard → Keyboard Shortcuts… → Spotlight → uncheck "Show Spotlight search". Then quit and reopen Lightswitch from its menu bar icon.

The build is ad-hoc signed, so every rebuild changes its signature and macOS drops the Accessibility grant. After a rebuild, run `tccutil reset Accessibility com.aftabkhan.lightswitch`, reopen the app and allow access again. To avoid this, create a self-signed code signing certificate named "Lightswitch Dev" in Keychain Access; `build.sh` uses it automatically.

The icon is drawn by `icon/make-icon.swift`; run `swift icon/make-icon.swift` to regenerate `icon/AppIcon.icns` after changing it.

## Notes

- Windows come from the Accessibility API, which only sees the current Space. Apps whose windows are all on other Spaces or in full screen appear as an "App" row, and selecting one activates the app.
- With an empty query, the list is in on-screen stacking order. The previous window is preselected, so ⌘Space then Return toggles between your last two windows.

## License

MIT. See [LICENSE](LICENSE).
