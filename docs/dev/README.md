# Tiler dev docs

Deep dives for the non-obvious parts of Tiler. These are written for a developer (human or agent) who is about to change something and needs to know why the current code is shaped the way it is. Each page ties the code to the commit that introduced or fixed it, so the rationale is auditable.

Start with [architecture.md](architecture.md) for the purity contract and the convergence loop that everything else hangs off of.

## Deep dives

- [architecture.md](architecture.md) — the Elm purity contract, the drain loop, and the frame-corrector convergence model (echo vs genuine move, the 3-attempt budget, min-width absorption).
- [window-identity.md](window-identity.md) — resolving `CGWindowID` ↔ `AXUIElement`, the multi-window ambiguity guard, orphan adoption, and exponential backoff.
- [window-filtering.md](window-filtering.md) — what makes a window tileable, and why `AXStandardWindow` alone is not enough.
- [native-tabs.md](native-tabs.md) — collapsing native tab groups to a single tile with a stable `GroupKey`, the `kAXMain` tiebreaker, and raise scoping.
- [focus.md](focus.md) — keeping focus correct across AX notification gaps, app activation, and multi-monitor setups.
- [screen-lifecycle.md](screen-lifecycle.md) — lock/unlock reaping suppression, display-reconfiguration debounce, and the fullscreen min-width trap.
- [ax-integration.md](ax-integration.md) — `AXObserver` subscription threading, refcon lifetime, and the `AXEnhancedUserInterface` frame-write workaround.
- [config-and-startup.md](config-and-startup.md) — config hot-reload, partial-write safety, and deferred startup until Accessibility is granted.

## Edge cases to verify before merging a tiling change

These are the behaviours that regress easily. Walk this list mentally (or with the live workflow below) before committing.

- **Native macOS tabs** — creating tabs (Cmd+T in Finder) and switching them (Cmd+Shift+[ / ]) must not create a new column; the background tab swap must be detected.
- **Non-standard windows** — dialogs, save sheets (`AXSheet`), open dialogs (`AXStandardWindow` without a close button), the Fonts panel (`AXFloatingWindow`), and Quick Look panels must be ignored.
- **Fullscreen** — entering fullscreen marks a window non-tileable (skipped); exiting fullscreen must restore its previous column width without triggering minimum-width absorption.
- **Minimize/deminimize** — minimized windows must be cleanly reaped; unminimizing must place them back in the layout.
- **Workspace switching** — inactive workspaces must park windows off-screen; switching back must restore layouts and preserve state across restarts.
- **Multi-window same PID** — rapid simultaneous window creation from one process (e.g. Cmd+N in TextEdit) must track every window.
- **Column operations** — left/right consume/expel (boundary conditions must be safe no-ops), toggle tabbed mode, column navigation, reordering, and resizing.
- **Focus reliability** — navigation must target the correct screen even if the user clicked a window on another display beforehand.
- **State restore across restarts** — terminate Tiler, restart it, and verify windows return to their correct persisted workspaces.
- **Screen lock/unlock** — locking then unlocking must not reap every window or wipe workspace assignments.
- **Quit / crash** — on quit, windows from inactive workspaces must be gathered back onto the main screen; a crash must not strand them off-screen.

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

Look for `Added`, `tileable=`, `focus:`, `LayoutEngine`, `Parked`, `correct:` (frame corrector), and `AX EUI:` markers.

### Safe test apps

Only test with apps that cannot mutate your environment:

- **TextEdit** — standard multi-window app; good for vertical stacking and basic layout.
- **Ghostty** — modern terminal with native macOS tabs; also exercises the `AXEnhancedUserInterface` workaround.
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

When a window behaves unexpectedly, inspect it with a small Swift script using `CGWindowListCopyWindowInfo` and `AXUIElementCopyAttributeValue` to check role, subrole, close-button presence (`kAXCloseButtonAttribute`), and minimized/fullscreen attributes. This is the fastest way to diagnose window-tracking failures — most "window won't tile" bugs are a `WindowFilter` or `WindowStore` decision, not a layout bug.

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

## Project structure

```
Sources/
├── TilerApp/           # Application entry point, menu bar, defaults
│   ├── main.swift
│   ├── AppDelegate.swift
│   └── StatusBarController.swift
└── TilerCore/          # Core tiling engine
    ├── Config/         # TOML config loading and types
    ├── Events/         # AXObserver and NSWorkspace event plumbing
    ├── Extensions/     # Display ID utilities
    ├── Hotkey/         # Carbon global hotkey registration + Action enum
    ├── Layout/         # Layout engine, geometry, viewport calculation
    ├── Persistence/    # State serialization (JSON)
    ├── Reducer/        # Pure state reducer + effects
    ├── State/          # State model types
    └── WindowManager/  # Orchestration, AX bridge, reconciliation, WindowStore
Resources/
├── Info.plist          # App bundle metadata
└── config.toml.example # Example configuration
Tests/
└── TilerCoreTests/     # Pure-data unit tests
```

## Build, test, package

```sh
swift build          # debug build
swift test --disable-sandbox   # unit tests (the flag avoids SwiftPM's sandbox-exec in some envs)
make app             # release build + ad-hoc signed TilerApp.app
make app SIGN_IDENTITY="..."   # codesign with a developer identity
make clean           # remove build artifacts and the .app bundle
```