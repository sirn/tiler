# Configuration

Tiler reads its configuration from `~/.config/tiler/config.toml`. The file is re-read automatically when it changes — no restart required. An annotated example ships at [`Resources/config.toml.example`](../Resources/config.toml.example).

```sh
cp Resources/config.toml.example ~/.config/tiler/config.toml
```

## General

```toml
[general]
outer_gaps = 8            # Gap between screen edge and outermost windows (points)
inner_gaps = 6            # Gap between windows stacked in a column
column_gaps = 8           # Gap between adjacent columns
min_window_width = 300    # Minimum window width before tiling stops resizing (points)
min_window_height = 250   # Minimum window height (points)
focus_column_wrap = false # Wrap focus_column_left/right within the active screen
                          # instead of crossing to the adjacent display
```

## Layout

```toml
[layout]
default_column_width = 0.5        # Width fraction for new columns (0.0–1.0 of usable width)
center_focused_column = "never"   # When to scroll the viewport to centre the focused column
always_center_single_column = false
```

### `center_focused_column`

Mirrors Niri's `center-focused-column`:

| Value | Behaviour |
|-------|-----------|
| `"never"` | Scroll the focused column fully into view; never centre it (default) |
| `"on-overflow"` | Centre the focused column only when it is wider than the viewport |
| `"always"` | Always centre the focused column (may leave blank space at the strip edges) |

### `always_center_single_column`

Mirrors Niri's `always-center-single-column`. When `true`, a workspace with a single column is always centred, regardless of `center_focused_column`. Centring bypasses the scroll clamp, so blank space may appear at the strip edges — matching Niri.

## Workspaces

```toml
[workspaces]
count = 9   # Number of workspaces (1–9). Default is 9.
```

## Keybinds

Keybindings are defined as `[[keybind]]` array-of-tables entries. See [keybindings](keybindings.md) for the full action list, key names, and the default bindings.

```toml
[[keybind]]
keys = "ctrl+alt+h"
action = "focus_column_left"

[[keybind]]
keys = "ctrl+alt+1"
action = "focus_workspace"
args = ["1"]
```

## App rules

Per-application overrides matched against the bundle identifier using simple wildcard patterns (`*` matches any sequence of characters, case-insensitive).

```toml
[[app_rule]]
app = "com.apple.finder"
action = "float"          # Exclude the app from tiling

[[app_rule]]
app = "com.tinyspeck.slackmacgap"
column_width = 0.4        # Preferred column width for this app

[[app_rule]]
app = "com.apple.*"
action = "float"          # Float all Apple apps
```

| Field | Description |
|-------|-------------|
| `app` | Bundle identifier pattern (`*` wildcard, case-insensitive) |
| `action` | Optional. `float` excludes the app from tiling |
| `column_width` | Optional. Preferred width fraction (0.0–1.0) for windows of this app |