<img src="icon/AppIcon-1024.png" width="128" alt="Lightswitch icon">

# Lightswitch

**[aftab404.github.io/lightswitch](https://aftab404.github.io/lightswitch/)**

![Lightswitch: type a few letters of a window's title and jump to it](media/lightswitch-demo.gif)

Spotlight-style fuzzy window switcher that opens apps too. Press ⌘Space (or a shortcut you pick) and start typing a window title or app name. Installed apps that aren't running yet are listed under Applications, below the matching windows. Tab / Shift-Tab (or ↑/↓, ⌃N/⌃P) move the selection, Return jumps to that window or opens that app, and Esc clears the query or closes the panel.

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

Either way, the app runs as a menu bar item and starts at login once it's in an Applications folder. You can turn that off in the menu.

## One-time setup

1. **Accessibility:** System Settings → Privacy & Security → Accessibility → enable Lightswitch. It needs this to read window titles and raise windows.
2. **Free up ⌘Space, or pick another shortcut:** Spotlight uses ⌘Space out of the box. Lightswitch opens apps as well, so handing it ⌘Space doesn't cost you Spotlight's app launching. Either go to System Settings → Keyboard → Keyboard Shortcuts… → Spotlight and uncheck "Show Spotlight search" (or give Spotlight another shortcut), or keep Spotlight and choose **Change Shortcut…** from the menu bar icon to give Lightswitch a different one, such as ⌥Space. If macOS still uses Lightswitch's shortcut for something else, Lightswitch tells you what and takes the shortcut over as soon as it's free.

The build is ad-hoc signed, so every rebuild changes its signature and macOS drops the Accessibility grant. After a rebuild or an update, choose **Grant Accessibility Access…** from the menu bar icon (or **Allow…** in the panel). It clears the stale entry so macOS asks again. To avoid this, create a self-signed code signing certificate named "Lightswitch Dev" in Keychain Access; `build.sh` uses it automatically.

The icon is drawn by `icon/make-icon.swift`; run `swift icon/make-icon.swift` to regenerate `icon/AppIcon.icns` after changing it.

## Notes

- Windows come from the Accessibility API, which only sees the current Space. Apps whose windows are all on other Spaces or in full screen appear as an "App" row, and selecting one activates the app.
- With an empty query, the list is in on-screen stacking order. The previous window is preselected, so ⌘Space then Return toggles between your last two windows.
- Apps come from `/Applications`, `/System/Applications` and `~/Applications` (including folders one level down, such as Utilities), plus Finder. Lightswitch lists them in the background at launch, and again when you open the panel if that list is a few minutes old or one of those folders has changed. Running apps aren't repeated under Applications, since they're already in the window list.

## License

MIT. See [LICENSE](LICENSE).
