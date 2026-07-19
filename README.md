# Tiler

A scrollable tiling window manager for macOS, inspired by [Niri](https://github.com/niri-wm/niri).

Tiler arranges windows into horizontally scrollable columns. Focus moves the viewport so your active column stays centered. Columns can hold stacked windows (vertical tiling) or tabbed windows (single visible).

## Status

Alpha — daily-driver quality, but expect rough edges.

## Features

- **Horizontal scrolling workspace** — columns spill off-screen; the viewport scrolls to keep the focused column centered
- **Stack and tab modes** — columns stack windows vertically or show one at a time (tabbed)
- **Consume/expel** — merge a column into its neighbor or split it back out
- **Workspaces** — up to 9 independent workspaces with keyboard switching
- **Multi-display** — focus and move windows between screens
- **Per-app rules** — float specific apps, set preferred column widths
- **Adaptive column widths** — columns remember minimum widths for windows that resist sizing
- **Native tab group support** — tracks background tabs in Chromium, Ghostty, Terminal, etc.
- **State persistence** — workspace layouts survive process restarts (sleep/wake, crashes)
- **Configurable keybindings** — all actions are bound via `~/.config/tiler/config.toml`

## Requirements

- macOS 13 Ventura or later
- Accessibility access (System Settings → Privacy & Security → Accessibility)

## Installation

### Build from source

```sh
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

## First launch

Grant Accessibility access when prompted, then copy the example config to start customizing:

```sh
cp Resources/config.toml.example ~/.config/tiler/config.toml
```

Configuration is re-read automatically when the file changes — no restart needed.

## Documentation

- **[Configuration](docs/configuration.md)** — all config options (`[general]`, `[layout]`, `[workspaces]`, app rules)
- **[Keybindings](docs/keybindings.md)** — available actions, key names, and the default bindings
- **[Developer docs](docs/dev/README.md)** — deep dives on architecture, window identity/filtering, native tabs, focus, screen lifecycle, AX integration, and config/startup, plus the live-debugging workflow

## Debugging

Set `TILER_DEBUG=1` to enable verbose logging:

```sh
TILER_DEBUG=1 open /Applications/TilerApp.app
```

Logs are emitted via `os_log` under subsystem `co.cakework.Tiler`:

```sh
log stream --predicate 'subsystem == "co.cakework.Tiler"'
```

See [edge cases & debugging](docs/dev/edge-cases.md) for the full live-debugging workflow.

## Acknowledgments

- [Niri](https://github.com/niri-wm/niri) — the scrollable-tiling concept this project is inspired by
- [AeroSpace](https://github.com/nikitabobko/AeroSpace) — reference for macOS tiling window manager patterns
- [TOMLKit](https://github.com/LebJe/TOMLKit) — TOML parsing