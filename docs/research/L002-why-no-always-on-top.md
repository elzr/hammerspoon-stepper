# Always-on-Top: Why It's Not Possible on macOS

## Summary

True always-on-top (AOT) — keeping a window from one app visually above the active app's windows — is **not possible** from Hammerspoon or any non-injecting tool on modern macOS. This is a fundamental OS-level restriction, not a Hammerspoon limitation.

Some apps (like Bear) can float their own windows because they call `NSWindow.level = .floating` from within their own process. The restriction only prevents *other processes* from changing your window level.

## How macOS Window Ordering Works

macOS manages window z-order using two mechanisms:

1. **Window levels** (CGWindowLevel): Each window has an integer level. Higher levels always render above lower levels. Normal app windows are at level 0. Floating panels are at level 3. The menu bar is at level 24.

2. **Within the same level**: The **active (frontmost) app** always has its windows above inactive apps. This is hardcoded in the window server. There is no API to override it.

This means: no matter what you do, when you click on Finder, all Finder windows will appear above all Chrome windows (both at level 0). The only escape is to promote the Chrome window to a higher level — which only Chrome itself (or a privileged system process) can do.

## Approaches Tested

### 1. AXRaise (hs.window:raise())

`AXRaise` is the accessibility action for "bring window to front." It only reorders windows **within the same application**. It cannot bring an inactive app's window above the active app.

- **Same-app**: Works (e.g., bring one Chrome window above another Chrome window)
- **Cross-app**: Does nothing visible

### 2. SkyLight Private API (SLSSetWindowLevel)

The SkyLight framework (`/System/Library/PrivateFrameworks/SkyLight.framework`) has `SLSSetWindowLevel(conn, windowID, level)` which should change a window's level.

**Tested from**:
- Python subprocess via `ctypes` — returns 0 (success), level reads back as changed via `SLSGetWindowLevel`, but **window server ignores it**
- Swift compiled helper — same result
- Lua C module loaded inside Hammerspoon's process (with accessibility TCC permissions) — same result

The function "succeeds" but the window server silently refuses to honor level changes made by non-owner processes. This is a security restriction in modern macOS (post-SIP).

`SLSOrderWindow` (reorder a window in the z-stack) explicitly fails with error code 1000 (permission denied) from any external process.

### 3. AXSubrole Change

Attempted setting `AXSubrole` from `AXStandardWindow` to `AXFloatingWindow` via `hs.axuielement`. The attribute is read-only — `isAttributeSettable` returns false.

### 4. Focus-Swap

Sequence: focus the AOT window (brings its app to front), then re-activate the original app for keyboard focus.

Problem: activating the original app immediately brings its windows back to front, covering the AOT window. There is no way to give an app keyboard focus without also bringing its windows to front. Setting `AXFocused` via accessibility only works within the same app.

## App-Native AOT Support

Some apps implement AOT themselves by calling `NSWindow.level` from within their own process. This works because the restriction only applies to *cross-process* level changes.

| App | Native AOT? | Details |
|-----|-------------|---------|
| **Bear** | Yes | `Window > Float on Top` on any note window. Also via `bear://x-callback-url/open-note?float=yes`. Toggleable from Hammerspoon via AX menu scripting. |
| **Kitty** | No | `kitten panel --layer top` exists for widget panels, but not for regular terminal windows. |
| **Chrome** | No | Document PiP API for web content only — not for the browser window itself. No command-line flag. |
| **VS Code** | Partial (v1.100+) | Floating/auxiliary windows only (drag a tab out, then pin icon or `workbench.action.toggleWindowAlwaysOnTop`). Main window AOT was explicitly rejected by maintainers. |
| **Cursor** | Partial (inherited) | Same as VS Code — floating windows only. |
| **VLC, QuickTime** | Yes | Video PiP windows float natively. |

### Bear: Programmable AOT

Bear is the most automation-friendly. Three ways to trigger float:

1. **URL scheme**: `bear://x-callback-url/open-note?id=NOTE_ID&new_window=yes&float=yes`
2. **AX menu scripting**: Click `Window > Float on Top` via `hs.axuielement` or AppleScript
3. **macOS keyboard shortcut**: Assign a custom shortcut to "Float on Top" via System Settings > Keyboard > Keyboard Shortcuts > App Shortcuts

### VS Code / Cursor: Partial AOT

Only for auxiliary windows (tabs dragged out of the main window). The main editor window cannot be floated. To toggle:
- Pin icon in the floating window title bar
- Command palette: `workbench.action.toggleWindowAlwaysOnTop`
- No default keyboard shortcut (bindable via settings)

## What Would Enable Universal AOT

- **yabai** (with scripting addition): Injects code into the Dock process, which has the required privileges to call `SLSSetWindowLevel` for any window. Requires partially disabling SIP.
- **Apple adding a system-level feature**: A "Float on Top" option in the Window menu or title bar for all apps (like Windows has had for decades via third-party tools, and natively since PowerToys). This would be the clean solution.
- **Each app implementing it individually**: The piecemeal approach — each app adds its own `NSWindow.level` toggle, like Bear did.

## What Hammerspoon Can Do

- **Same-app z-order**: `raise()` and `sendToBack()` work for reordering windows within the same application.
- **Bring to top on demand**: `focus()` brings a window to front (by activating its app). Good for a hotkey that summons a specific window, but not for persistent always-on-top.
- **Canvas overlays**: `hs.canvas` at `windowLevels.floating` genuinely floats above everything. Could be used for a read-only mirror of a window (screenshot-based PiP), but the user can't interact with the overlay.
- **Trigger app-native AOT**: For apps like Bear that expose float-on-top via menus or URL schemes, Hammerspoon can automate toggling it on/off.

## Conclusion

Per-window always-on-top requires changing the window's level in the macOS window server. The window server only allows this from the process that owns the window, or from a privileged system process (like the Dock). No amount of accessibility permissions, private API calls, or clever focus-swapping can work around this restriction.

The fn+shift+cmd+up binding is left unbound for future use.
