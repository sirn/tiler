# Configuration

Config file: `~/.config/tiler/config.toml`. Re-read automatically on change; no restart required. Example: [`Resources/config.toml.example`](../Resources/config.toml.example).

```sh
cp Resources/config.toml.example ~/.config/tiler/config.toml
```

## `[general]`

### `outer_gaps`

- Type: number (points)
- Default: `8`

Gap between the screen edge and the outermost windows.

### `inner_gaps`

- Type: number (points)
- Default: `6`

Gap between windows stacked vertically in the same column.

### `column_gaps`

- Type: number (points)
- Default: `8`

Gap between adjacent columns.

### `min_window_width`

- Type: number (points)
- Default: `300`

Minimum window width. The frame corrector stops trying to shrink a window below this and absorbs the observed width into the column. See [dev/architecture/03-windowmanager.md](dev/architecture/03-windowmanager.md#bounded-corrector).

### `min_window_height`

- Type: number (points)
- Default: `250`

Minimum window height. Analogous to `min_window_width`.

### `focus_column_wrap`

- Type: boolean
- Default: `false`

When `true`, `focus_column_left` / `focus_column_right` wrap within the active screen instead of crossing to the adjacent display.

## `[layout]`

### `default_column_width`

- Type: number (a proportion, `0.0`–`1.0`) or string (`"900px"`)
- Default: `0.5`

Width applied to newly created columns. A proportion is a share of the slot width, which is the usable width plus one gap, and each column keeps one gap for itself. Proportions that add up to `1.0` therefore fill the screen exactly. A `"<points>px"` string gives a fixed width that no viewport size changes.

### `center_focused_column`

- Type: string enum
- Default: `"never"`

When to scroll the viewport so the focused column is centred. Mirrors Niri's `center-focused-column`.

| Value | Behaviour |
|-------|-----------|
| `"never"` | Scroll the focused column fully into view; never centre it. |
| `"on-overflow"` | Centre the focused column only when it is wider than the viewport. |
| `"always"` | Always centre the focused column. May leave blank space at the strip edges. |

### `always_center_single_column`

- Type: boolean
- Default: `false`

When `true`, a workspace with a single column is always centred, regardless of `center_focused_column`. Centring bypasses the scroll clamp, so blank space may appear at the strip edges. Mirrors Niri's `always-center-single-column`.

## `[workspaces]`

### `count`

- Type: integer (`1`–`9`)
- Default: `9`

Number of workspaces. Workspace indices passed to `focus_workspace` / `move_to_workspace` must be within this range.

## `[[keybind]]`

Array-of-tables; each entry maps a key combination to an action. See [keybindings.md](keybindings.md) for the action list, key names, and defaults.

```toml
[[keybind]]
keys = "ctrl+alt+h"
action = "focus_column_left"

[[keybind]]
keys = "ctrl+alt+1"
action = "focus_workspace"
args = ["1"]
```

### `keys`

- Type: string
- Required.

Key combination: modifiers joined with `+`, then a key name. Modifiers: `ctrl`, `alt` / `option`, `cmd` / `command`, `shift`.

### `action`

- Type: string
- Required.

Action name. See [keybindings.md](keybindings.md#available-actions).

### `args`

- Type: array of strings
- Optional.

Action arguments. Used by `focus_workspace` and `move_to_workspace` (the workspace index as a string, e.g. `["3"]`).

## `[[app_rule]]`

Array-of-tables; each entry overrides tiling behavior for windows matching a bundle identifier pattern.

```toml
[[app_rule]]
app = "com.apple.finder"
action = "float"

[[app_rule]]
app = "com.tinyspeck.slackmacgap"
column_width = 0.4

[[app_rule]]
app = "com.apple.*"
action = "float"
```

### `app`

- Type: string
- Required.

Bundle identifier pattern. `*` matches any sequence of characters; matching is case-insensitive.

### `action`

- Type: string
- Optional.

`float` excludes matching windows from tiling.

### `column_width`

- Type: number (a proportion, `0.0`–`1.0`) or string (`"900px"`)
- Optional.

Preferred width for windows of matching apps when placed in a new column. Takes a proportion or a fixed width, like `default_column_width`.