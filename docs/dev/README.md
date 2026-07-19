# Tiler internals

Reference documentation for Tiler internals. Each section links the code to the commit that introduced or fixed the behavior.

New readers: read [Concepts and vocabulary](#concepts-and-vocabulary) below first, then [architecture.md](architecture.md).

## What Tiler is

Tiler is a scrollable tiling window manager for macOS, inspired by Niri (see the root [README](../../README.md) for the user-facing overview). It arranges windows into columns on a horizontally scrolling workspace and keeps the focused column in view by scrolling the viewport rather than moving windows. The rest of these docs assume the concepts below.

## Concepts and vocabulary

Terms used throughout these docs:

- **Workspace** — one of up to 9 independent layouts. Each screen has one active workspace; switching parks the previous one off-screen and shows the new one.
- **Strip / viewport** — the strip is the total width of every column in a workspace laid end to end. Only part of it fits on screen at once; that visible part is the viewport. Moving focus to a column outside the viewport scrolls it into view (computed by `ViewportCalc`).
- **Column** — a narrow vertical band within a strip containing one or more windows. Columns are laid out left to right across a workspace. A column has a width fraction of the usable screen and a mode: **stack** (windows tiled vertically within the column) or **tab** (one window visible).
- **Window node (tile)** — a managed window inside a column. Tracked by `CGWindowID`, acted on through `AXUIElement` (see [window-identity.md](window-identity.md)).
- **GroupKey** — a stable tile identity that survives native tab swaps, independent of the current `CGWindowID` (see [native-tabs.md](native-tabs.md)).
- **Focus** — the focused column and the focused window within it. Navigation actions move focus (see [focus.md](focus.md)).
- **Floating** — a window excluded from tiling (`toggle_float`, or an `app_rule` with `action = "float"`); not placed by the layout.
- **Retile** — recompute the frame for every managed window from the current state and write it via AX.
- **Reconcile** — discover windows from `CGWindowList` + AX, diff against the managed set, add new tileable windows, and **reap** (remove) gone ones.
- **Miss / reap** — a managed window absent from `CGWindowList` for one pass is a *miss*; after a threshold of consecutive misses it is reaped. Reaping is suppressed when observations are unreliable (see [screen-lifecycle.md](screen-lifecycle.md)).
- **Park** — move a window off-screen (a 1px sliver) so an inactive workspace's windows are not visible.
- **Consume / expel** — merge a column into a neighbor, or split it back out.
- **Reducer** — the pure function `Reducer.apply(action, to: &state, env) -> [Effect]` that mutates state (see [architecture.md](architecture.md)).
- **Effect** — a value describing a side-effect (retiling, focusing, closing) returned by the reducer and executed by the shell.
- **Shell** — `WindowManager`; runs effects against AX/CG, the drain loop, and persistence.
- **Drain loop** — the coalesced retile/corrector cycle on the main thread (see [architecture.md](architecture.md)).
- **Frame corrector** — re-issues frames until windows converge, distinguishing the shell's own writes (**echo**) from user drags (**genuine move**).
- **measuredMinWidth / measuredMinHeight** — a column's recorded minimum size, absorbed from windows that resist sizing (see [architecture.md](architecture.md), [screen-lifecycle.md](screen-lifecycle.md)).

`architecture.md` describes the convergence model the other sections depend on; read it after this section.

## Topics

- [architecture.md](architecture.md) — reducer purity contract, drain loop, frame-corrector convergence model.
- [window-identity.md](window-identity.md) — `CGWindowID` ↔ `AXUIElement` resolution and the multi-window ambiguity guard.
- [window-filtering.md](window-filtering.md) — tileability rules and the close-button requirement.
- [native-tabs.md](native-tabs.md) — native tab group collapse and the `kAXMain` tiebreaker.
- [focus.md](focus.md) — focus tracking across AX notification gaps and multi-monitor.
- [screen-lifecycle.md](screen-lifecycle.md) — lock/unlock reaping suppression, display reconfiguration, fullscreen min-width guard.
- [ax-integration.md](ax-integration.md) — `AXObserver` threading and the `AXEnhancedUserInterface` workaround.
- [config-and-startup.md](config-and-startup.md) — config hot-reload, partial-write safety, deferred accessibility startup.

## Edge cases

Behaviors that regress easily. Verify before merging a tiling change.

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

## Debugging

Procedures for building, launching, and inspecting a live Tiler instance.

### Build and launch with debug logging

```sh
swift build
TILER_DEBUG=1 .build/debug/TilerApp
```

Run under a terminal multiplexer or background runner so the process keeps running after the terminal exits.

### Stream logs

```sh
log stream --predicate 'subsystem == "co.cakework.Tiler"' --style compact --info
```

Relevant markers: `Added`, `tileable=`, `focus:`, `LayoutEngine`, `Parked`, `correct:` (frame corrector), `AX EUI:`.

### Safe test apps

- **TextEdit** — standard multi-window app; vertical stacking and basic layout.
- **Ghostty** — native macOS tabs; also exercises the `AXEnhancedUserInterface` workaround.
- **Finder** — native tabs (Cmd+T) and multi-window (Cmd+N).
- **Calculator** — small rigid window; minimum-size and filtering tests.

Do not launch apps that modify state, system settings, network, or disk during a test loop.

### Simulating input

Post `CGEvent` keyDown/keyUp pairs from a helper Swift script:

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

Inspect a misbehaving window with a Swift script using `CGWindowListCopyWindowInfo` and `AXUIElementCopyAttributeValue` to check role, subrole, close-button presence (`kAXCloseButtonAttribute`), and minimized/fullscreen attributes. Most "window won't tile" bugs are a `WindowFilter` or `WindowStore` decision, not a layout bug.

### Workflow

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
swift test --disable-sandbox   # unit tests (avoids SwiftPM's sandbox-exec in some envs)
make app             # release build + ad-hoc signed TilerApp.app
make app SIGN_IDENTITY="..."   # codesign with a developer identity
make clean           # remove build artifacts and the .app bundle
```