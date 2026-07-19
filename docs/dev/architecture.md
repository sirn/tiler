# Architecture

Tiler implements a pure Elm-like architecture: **State → Actions → Reducer → Effects → Shell**. The boundary between pure and impure code is strict and load-bearing — every macOS API call (Accessibility, CoreGraphics) lives outside the reducer.

## Data flow

1. **Events** — hotkey presses (Carbon) and system events (`AXObserver`, `NSWorkspace`, `CGWindowList` reconciliation) are translated into `Action` values.
2. **Reducer** — `Reducer.apply(action, to: &state, env)` is a **pure** function. It mutates `TilerState` and returns `[Effect]`. It must never perform I/O or call AX/CG directly.
3. **Effects** — the returned `Effect` values describe side-effects (retiling, focusing a window, closing a window, logging) without executing them.
4. **Shell** — `WindowManager` runs the effects against the real AX/CG APIs, then drains the resulting state changes (retile/reconcile) until the system converges.

This separation keeps the tiling logic testable: `Tests/TilerCoreTests/` exercises the reducer and layout on pure data structures, with no AX or CG interaction.

## Key subsystems

- **WindowManager** — main orchestrator; runs the reconcile/retile drain loop, owns AX integration, and persists state.
- **Reconciler** — periodically discovers windows via `CGWindowList` + AX, diffs them against the tile set, and adds/reaps tiles accordingly.
- **LayoutEngine** — computes screen-space frames for each window given workspaces, column widths, gaps, and viewport offset.
- **ViewportCalc** — determines which columns are visible and how far to scroll to keep focus in view (implements `center_focused_column` and `always_center_single_column`).
- **EventBroker** — wraps `AXObserver` callbacks and `NSWorkspace` notifications into a unified `TilerEvent` stream.
- **WindowStore** — maintains the mapping from `CGWindowID` to `AXUIElement`, with fallback resolution for Chromium-style AX orphans.
- **StatePersistence** — saves workspace layouts to `~/Library/Application Support/tiler/state.json` on every mutation and restores them on launch.

## Convergence model

When Tiler issues frame changes it tracks each window's desired frame with an epoch counter and a correction budget. Geometry-change notifications are classified as either:

- `.echo` — the window reached its target; ignore.
- `.genuineMove` — the user dragged the window; snap it back.

The corrector re-issues frames up to 3 times for windows that resist sizing, then either absorbs the minimum width or accepts the settled frame. This is what makes the `absorbMinWidth` guard and the `wasNotTileableLastPass` stickiness necessary — see [edge cases](edge-cases.md).

## Lifecycle

1. **Launch** — `TilerApp` creates the `WindowManager`, loads config from `~/.config/tiler/config.toml`, registers global hotkeys, and restores persisted state.
2. **Steady state** — the reconcile/retile drain loop runs continuously: discover windows → diff against state → dispatch actions → run effects → retiling until converged.
3. **Config reload** — the config file is watched; changes are re-parsed and applied without restarting.
4. **Persistence** — every state mutation writes `state.json`; on the next launch the saved workspaces, columns, and widths are restored.
5. **Termination** — windows are left in place; Tiler's last persisted state is already on disk.

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
    ├── Hotkey/         # Carbon global hotkey registration
    ├── Layout/         # Layout engine, geometry, viewport calculation
    ├── Persistence/    # State serialization (JSON)
    ├── Reducer/        # Pure state reducer + effects
    ├── State/          # State model types
    └── WindowManager/  # Orchestration, AX bridge, reconciliation
Resources/
├── Info.plist          # App bundle metadata
└── config.toml.example # Example configuration
Tests/
└── TilerCoreTests/     # Unit tests
```

## Build, test, package

```sh
swift build          # debug build
swift test           # run the pure-data unit tests (no AX/CG access needed)
make app             # release build + ad-hoc signed TilerApp.app
make app SIGN_IDENTITY="..."   # codesign with a developer identity
make clean           # remove build artifacts and the .app bundle
```

Dependencies: [TOMLKit](https://github.com/LebJe/TOMLKit) (TOML parsing) is the only external dependency. Frameworks: AppKit, ApplicationServices (Accessibility), CoreGraphics, Carbon.