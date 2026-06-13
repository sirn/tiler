# Tiler

A scrollable tiling macOS Window Manager inspired by [Niri](https://github.com/niri-wm/niri).

Tiler arranges windows into horizontally scrollable columns. Focus moves the viewport so your active column stays centered. Columns can hold stacked windows (vertical tiling) or tabbed windows (single visible).

## Status

Alpha. Daily-driver quality but expect rough edges.

## Features

- **Horizontal scrolling workspace** — columns spill off-screen; the viewport scrolls to keep the focused column centered
- **Stack and tab modes** — columns stack windows vertically or show one at a time (tabbed)
- **Consume/expel** — merge a column into its neighbor or split it back out
- **Workspaces** — up to 9 independent workspaces with keyboard switching
- **Per-app rules** — float specific apps, set preferred column widths
- **Adaptive column widths** — columns remember minimum widths for windows that resist sizing
- **Native tab group support** — tracks background tabs in Chromium, Ghostty, Terminal, etc.
- **State persistence** — workspace layouts survive process restarts (sleep/wake, crashes)
- **Configurable keybindings** — all actions are bound via ~/.config/tiler/config.toml

## Requirements

- macOS 13 Ventura or later
- Accessibility access (System Settings → Privacy & Security → Accessibility)

## Installation

### Build from source

```sh
# Clone and enter the repository
git clone https://git.sr.ht/~sirn/tiler
cd tiler

# Build and package as TilerApp.app
make app

# Or with a developer certificate for signing
make app SIGN_IDENTITY="Apple Development: Your Name (DEVELOPERID)"
```

Drag `TilerApp.app` to your Applications folder. On first launch, macOS will prompt for Accessibility access.

### Updating

```sh
git pull
make app
# Replace TilerApp.app in /Applications
```

## Configuration

Copy the example config to `~/.config/tiler/config.toml` and modify as needed:

```sh
cp config.toml.example ~/.config/tiler/config.toml
```

Configuration is re-read when Tiler detects a change to the file (no restart required).

### General

```toml
[general]
outer_gaps = 8       # Gap between screen edge and outer windows (points)
inner_gaps = 6       # Gap between stacked windows in a column
column_gaps = 8      # Gap between adjacent columns
```

### Layout

```toml
[layout]
default_column_width = 0.5   # Default width fraction for new columns (0.0–1.0)
center_focused_column = true # Whether to scroll viewport to center focused column
```

### Workspaces

```toml
[workspaces]
count = 9   # Number of workspaces (1–9). Default is 9.
```

### Keybindings

All actions available for binding:

| Action | Description |
|--------|-------------|
| `focus_column_left` / `focus_column_right` | Move focus between columns |
| `move_column_left` / `move_column_right` | Swap focused column with neighbor |
| `focus_window_up` / `focus_window_down` | Move focus within a stacked column |
| `move_window_up` / `move_window_down` | Reorder window within a column |
| `focus_workspace <n>` | Switch to workspace n (1–9) |
| `move_to_workspace <n>` | Move focused window to workspace n |
| `increase_column_width` / `decrease_column_width` | Adjust column width by 5% |
| `toggle_column_tabbed` | Toggle between stack and tab mode |
| `close_window` | Close the focused window |
| `toggle_fullscreen` | Toggle fullscreen on the focused window |
| `consume_or_expel_left` / `consume_or_expel_right` | Merge column with neighbor or split |
| `toggle_float` | Toggle floating mode on the focused window |

Modifier prefixes: `ctrl`, `alt`/`option`, `cmd`/`command`, `shift`

Key names: `a`–`z`, `0`–`9`, `f1`–`f12`, `space`, `return`, `tab`, `escape`, `comma`, `period`, `slash`, `semicolon`, `quote`, `backtick`, `backslash`, `minus`, `equal`, `bracketleft`, `bracketright`, `left`, `right`, `up`, `down`

### App Rules

Per-application overrides matched against bundle identifier using simple wildcard patterns (`*` matches any sequence of characters, case-insensitive):

```toml
[[app_rule]]
app = "com.apple.finder"
action = "float"          # Exclude app from tiling

[[app_rule]]
app = "com.tinyspeck.slackmacgap"
column_width = 0.4        # Preferred column width for this app

[[app_rule]]
app = "com.apple.*"
action = "float"          # Float all Apple apps
```

### Default Keybindings

| Keys | Action |
|------|--------|
| `ctrl+alt+h` / `ctrl+alt+l` | Focus column left/right |
| `ctrl+alt+j` / `ctrl+alt+k` | Focus window down/up |
| `ctrl+alt+shift+h` / `ctrl+alt+shift+l` | Move column left/right |
| `ctrl+alt+shift+j` / `ctrl+alt+shift+k` | Move window down/up |
| `ctrl+alt+1`–`9` | Focus workspace 1–9 |
| `ctrl+alt+shift+1`–`9` | Move window to workspace 1–9 |
| `ctrl+alt+,` / `ctrl+alt+.` | Decrease/increase column width |
| `ctrl+alt+t` | Toggle column tabbed mode |
| `ctrl+alt+q` | Close window |
| `ctrl+alt+[` / `ctrl+alt+]` | Consume/expel left/right |
| `ctrl+alt+f` | Toggle floating mode |

## Debugging

Set `TILER_DEBUG=1` in the environment to enable verbose logging:

```sh
TILER_DEBUG=1 open /Applications/TilerApp.app
# or from a terminal session
launchctl setenv TILER_DEBUG 1
open /Applications/TilerApp.app
```

Logs are emitted via `os_log` under subsystem `co.cakework.Tiler`, category `tiler`:

```sh
log stream --predicate 'subsystem == "co.cakework.Tiler"'
```

## Architecture

Tiler uses an Elm-like architecture:

- **State** — `TilerState` holds all application state: screens, workspaces, columns, window nodes
- **Actions** — hotkey presses or system events produce `Action` values
- **Reducer** — `Reducer.apply(action, to: &state, env)` is a pure function that returns `[Effect]`
- **Effects** — side-effects like retiling, focusing, closing windows, or logging
- **Shell** — `WindowManager` orchestrates: it receives events, dispatches actions to the reducer, and runs the resulting effects against the real AX/CG APIs

### Key subsystems

- **WindowManager** — main orchestrator; manages the reconcile/retile drain loop, AX integration, and state persistence
- **Reconciler** — periodically discovers windows via `CGWindowList` + AX, compares with the tile set, and adds/reaps tiles accordingly
- **LayoutEngine** — computes screen-space frames for each window given the current workspaces, column widths, gaps, and viewport offset
- **ViewportCalc** — determines which columns are visible and how far to scroll to keep focus in view
- **EventBroker** — wraps `AXObserver` callbacks and `NSWorkspace` notifications into a unified `TilerEvent` stream
- **WindowStore** — maintains the mapping from `CGWindowID` to `AXUIElement`, with fallback resolution for Chromium-style AX orphans
- **StatePersistence** — saves workspace layouts to `~/Library/Application Support/tiler/state.json` on every mutation and restores them on launch

### Convergence model

When Tiler issues frame changes, it tracks each window's desired frame with an epoch counter and a correction budget. Geometry-change notifications are classified as either `.echo` (window reached its target — ignore) or `.genuineMove` (user dragged the window — snap back). The corrector re-issues frames up to 3 times for windows that resist sizing, then either absorbs the minimum width or accepts the settled frame.

## Development

### Building

```sh
swift build
```

### Testing

```sh
swift test
```

Tests cover the reducer, column operations, layout geometry, viewport calculation, and reconciliation logic. They operate on pure data structures and require no AX or CG interaction.

### Packaging

```sh
make app       # ad-hoc signed .app bundle
make clean     # remove build artifacts and .app bundle
```

The `app` target builds a release binary and assembles it into `TilerApp.app` with proper codesigning.

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

## Acknowledgments

- [Niri](https://github.com/niri-wm/niri) — the scrollable-tiling concept this project is inspired by
- [AeroSpace](https://github.com/nikitabobko/AeroSpace) — reference for macOS tiling window manager patterns
- [TOMLKit](https://github.com/LebJe/TOMLKit) — TOML parsing
