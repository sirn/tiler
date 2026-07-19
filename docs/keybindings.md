# Keybindings

Keybindings live under `[[keybind]]` entries in `~/.config/tiler/config.toml`. Each entry maps a key combination to an action:

```toml
[[keybind]]
keys = "ctrl+alt+h"
action = "focus_column_left"

[[keybind]]
keys = "ctrl+alt+1"
action = "focus_workspace"
args = ["1"]
```

Workspace actions take a numeric argument via `args`:

```toml
[[keybind]]
keys = "ctrl+alt+shift+3"
action = "move_to_workspace"
args = ["3"]
```

## Available actions

| Action | Args | Description |
|--------|------|-------------|
| `focus_column_left` / `focus_column_right` | — | Move focus between columns |
| `move_column_left` / `move_column_right` | — | Swap the focused column with its neighbor |
| `focus_window_up` / `focus_window_down` | — | Move focus within a stacked column |
| `move_window_up` / `move_window_down` | — | Reorder the focused window within its column |
| `focus_workspace` | `<n>` | Switch to workspace n (1–9) |
| `move_to_workspace` | `<n>` | Move the focused window to workspace n |
| `focus_screen_previous` / `focus_screen_next` | — | Move focus to the previous/next display |
| `move_to_screen_previous` / `move_to_screen_next` | — | Move the focused window to the previous/next display |
| `increase_column_width` / `decrease_column_width` | — | Adjust the column width by 5% |
| `toggle_column_tabbed` | — | Toggle between stack and tab mode |
| `close_window` | — | Close the focused window |
| `toggle_fullscreen` | — | Toggle fullscreen on the focused window |
| `consume_or_expel_left` / `consume_or_expel_right` | — | Merge the column with its neighbor or split it back out |
| `toggle_float` | — | Toggle floating mode on the focused window |

## Key names

Modifier prefixes: `ctrl`, `alt`/`option`, `cmd`/`command`, `shift`, combined with `+`.

Key names: `a`–`z`, `0`–`9`, `f1`–`f12`, `space`, `return`, `tab`, `escape`, `comma`, `period`, `slash`, `semicolon`, `quote`, `backtick`, `backslash`, `minus`, `equal`, `bracketleft`, `bracketright`, `left`, `right`, `up`, `down`.

## Default keybindings

| Keys | Action |
|------|--------|
| `ctrl+alt+h` / `ctrl+alt+l` | Focus column left/right |
| `ctrl+alt+j` / `ctrl+alt+k` | Focus window down/up |
| `ctrl+alt+shift+h` / `ctrl+alt+shift+l` | Move column left/right |
| `ctrl+alt+shift+j` / `ctrl+alt+shift+k` | Move window down/up |
| `ctrl+alt+1`–`9` | Focus workspace 1–9 |
| `ctrl+alt+shift+1`–`9` | Move window to workspace 1–9 |
| `ctrl+alt+comma` / `ctrl+alt+period` | Decrease/increase column width |
| `ctrl+alt+t` | Toggle column tabbed mode |
| `ctrl+alt+q` | Close window |
| `ctrl+alt+bracketleft` / `ctrl+alt+bracketright` | Consume/expel left/right |

`toggle_float`, `toggle_fullscreen`, and the screen-switching actions have **no default binding** — add them to your config to use them.