# Edge cases & debugging

Tiler is at the alpha/daily-driver stage. This page collects the edge cases that are easy to regress, the known pitfalls behind them, and the workflow for debugging against a live instance.

## Edge cases to verify

When changing tiling logic, make sure these behaviours still hold:

- **Native macOS tabs** — creating tabs (Cmd+T in Finder) and switching them (Cmd+Shift+[ / ]) must not create a new column; the background tab swap must be detected.
- **Non-standard windows** — dialogs, save sheets (`AXSheet`), open dialogs (`AXStandardWindow` without a close button), the Fonts panel (`AXFloatingWindow`), and Quick Look panels must be ignored.
- **Fullscreen** — entering fullscreen marks a window non-tileable (skipped); exiting fullscreen must restore its previous column width without triggering minimum-width absorption.
- **Minimize/deminimize** — minimized windows must be cleanly reaped; unminimizing must place them back in the layout.
- **Workspace switching** — inactive workspaces must park windows off-screen; switching back must restore layouts and preserve state across restarts.
- **Multi-window same PID** — rapid simultaneous window creation from one process (e.g. Cmd+N in TextEdit) must track every window.
- **Column operations** — left/right consume/expel (boundary conditions must be safe no-ops), toggle tabbed mode, column navigation, reordering, and resizing.
- **Focus reliability** — navigation must target the correct screen even if the user clicked a window on another display beforehand (relies on `syncFocusedScreenFromAX`).
- **State restore across restarts** — terminate Tiler, restart it, and verify windows return to their correct persisted workspaces.

## Common pitfalls

- **Reducer purity** — never call Accessibility or CoreGraphics from reducer code. Side-effects go in `Effect` values run by the shell.
- **WindowFilter dialog checks** — checking for `AXStandardWindow` is insufficient. Many save/open dialogs report as standard windows but lack a close button; filter them by asserting the presence of `kAXCloseButtonAttribute`.
- **`absorbMinWidth` fullscreen guard** — when a window enters fullscreen its width matches the screen. Skip absorption when the observed width meets or exceeds the usable screen width (`observedWidth >= usableWidth`), or `absorbMinWidth` will lock column widths.
- **`wasNotTileableLastPass` stickiness** — fullscreen windows may vanish from `CGWindowList` for a few passes during screen transitions. The non-tileable set must remain sticky until the window returns or is fully reaped.
- **Lockfiles** — never edit `Package.resolved` by hand; regenerate with `swift package update`.
- **State file** — `~/Library/Application Support/tiler/state.json` (not in `.build/`).
- **Config file** — `~/.config/tiler/config.toml`; see `Resources/config.toml.example` for reference.

## Debugging a live instance

### Build and launch with debug logging

```sh
swift build
TILER_DEBUG=1 .build/debug/TilerApp
```

Run it under a terminal multiplexer or background runner so it keeps running after the terminal exits.

### Stream logs

```sh
log stream --predicate 'subsystem == "co.cakework.Tiler"' --style compact --info
```

Look for `Added`, `tileable=`, `focus:`, `LayoutEngine`, and `Parked` markers.

### Safe test apps

Only test with apps that cannot mutate your environment:

- **TextEdit** — standard multi-window app; good for vertical stacking and basic layout.
- **Ghostty** — modern terminal with native macOS tabs.
- **Finder** — native tabs (Cmd+T) and multi-window (Cmd+N).
- **Calculator** — small rigid window; good for minimum-size and filtering tests.

Do not launch apps that modify state, system settings, network, or disk during a test loop.

### Simulating input

When physical input isn't available, post `CGEvent` keyDown/keyUp pairs from a helper Swift script:

```swift
let source = CGEventSource(stateID: .hidSystemState)
let down = CGEvent(keyboardEventSource: source, virtualKey: 37, keyDown: true)
down?.flags = [.maskControl, .maskAlternate]
down?.post(tap: .cghidEventTap)
let up = CGEvent(keyboardEventSource: source, virtualKey: 37, keyDown: false)
up?.flags = [.maskControl, .maskAlternate]
up?.post(tap: .cghidEventTap)
```

Modifier flags: `ctrl = .maskControl`, `alt/option = .maskAlternate`, `shift = .maskShift`, `cmd = .maskCommand`.

Keycodes: H=4, J=38, K=40, L=37, T=17, Q=12, F=3, W=13, O=31, S=1, Escape=53, bracketleft=33, bracketright=30, comma=43, period=47, P=35, N=45, 1=18, 2=19, 3=20.

### AX inspection

When a window behaves unexpectedly, inspect it with a small Swift script using `CGWindowListCopyWindowInfo` and `AXUIElementCopyAttributeValue` to check roles, subroles, close-button presence (`kAXCloseButtonAttribute`), and minimized/fullscreen attributes. This is the fastest way to diagnose window-tracking failures.

### Testing workflow

1. `swift build && swift test` — clean build, all tests green.
2. Launch Tiler in debug mode.
3. Start `log stream` in a separate pane.
4. Launch safe test apps (TextEdit, Ghostty, Finder).
5. Exercise the change: send hotkeys, open/close/minimize windows.
6. Verify the log output.
7. Run the AX inspection helper if a window fails to tile.
8. Re-run `swift test` and restart Tiler to confirm the fix.

### Cleanup

```sh
pkill -f TilerApp
pkill -f 'log stream.*co.cakework'
rm -f ~/Library/Application\ Support/tiler/state.json   # reset persisted state if needed
osascript -e 'tell application "TextEdit" to quit saving no'
osascript -e 'tell application "Ghostty" to quit'
```