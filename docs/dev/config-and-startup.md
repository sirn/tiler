# Config and startup

Tiler loads config at startup, watches the config file for changes, and defers full startup until Accessibility access is granted. Workspace state is persisted on every mutation and recovered on the next launch, including from crashes that leave windows parked off-screen.

## Config hot-reload

`ConfigLoader` tracks the file mtime and exposes `reloadIfChanged()`, which re-reads and re-parses only when the mtime has advanced. A 2s poll timer (the reconcile poll cadence) applies a changed config through `WindowManager.applyConfig` (gaps, layout, workspace count, app rules, `focus_column_wrap`) and re-registers keybindings via `HotkeyDispatcher.setBindings`, which handles stop/start.

### Partial-write safety

`reloadIfChanged` returns nil on a missing file or parse error, so a half-written file never resets the running config to defaults. A truncating in-place write (shell redirection) can be observed mid-save as valid-but-incomplete TOML that parses to defaults — shrinking workspaces and relocating windows. The reload condition is mtime advanced and stable across two consecutive polls; atomic-saving editors are unaffected.

### Status bar

A hot-reloaded workspace count updates the status-bar workspace menu. Config options that affect a UI surface must be wired into `applyConfig` and the status bar — `setWorkspaceCount` runs on every reload, not just at startup, so the menu does not go stale.

## Deferred accessibility startup

Tiler requires Accessibility access. On launch it prompts once, then polls `AXIsProcessTrusted()` (no re-prompt) on a 2s timer and runs the startup sequence on the first false→true transition — no manual relaunch. The startup body is in `startCore()`, guarded by `windowManager == nil` so a duplicate timer fire cannot double-start. A degraded-mode status bar indicates waiting for permission.

## State persistence and crash recovery

Every state mutation writes `~/Library/Application Support/tiler/state.json`; on launch the saved workspaces, columns, and widths are restored.

On clean quit, `gatherWindowsToMainScreen()` runs from `applicationWillTerminate` before `saveState`: partially visible windows snap to the nearest edge of the main screen's visible frame, non-visible windows are centered, and windows already on the main screen are left alone.

On crash, `applicationWillTerminate` does not fire, so windows on inactive workspaces remain parked off-screen (a 1px sliver at the screen edge). On each retile Tiler writes managed window PIDs to a crash-recovery file and installs signal handlers (SIGSEGV, SIGABRT, …) that `posix_spawn` a fresh `TilerApp --crash-recovery` process to reposition stranded windows. Clean shutdown deletes the recovery file so the next launch does not mistake a quit for a crash. On launch, if the file exists, crash recovery runs before normal startup as a fallback.

`gatherWindowsToMainScreen()` and the crash-recovery file must stay in sync with the parking logic — a window stranded off-screen has no user-visible indication.

## File locations

- Config: `~/.config/tiler/config.toml` (example at `Resources/config.toml.example`)
- State: `~/Library/Application Support/tiler/state.json`
- Crash recovery file: written per-retile, deleted on clean shutdown

`Package.resolved` is regenerated with `swift package update`; do not edit it by hand.