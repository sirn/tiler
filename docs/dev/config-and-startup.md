# Config and startup: hot-reload, partial writes, and deferred accessibility

## Config hot-reload (commits `a318278`, `581f77e`)

Config is not read once at startup. `ConfigLoader` tracks the file's mtime and exposes `reloadIfChanged()`, which re-reads and re-parses only when the mtime has advanced. A 2s poll timer (the same cadence as the reconcile poll) calls it and applies a changed config through `WindowManager.applyConfig` (gaps, layout, workspace count, app rules, `focus_column_wrap`) and re-registers keybindings via `HotkeyDispatcher.setBindings`, which already handles stop/start.

### Partial-write safety

`reloadIfChanged` returns nil on a missing file or parse error so a half-written file never resets the running config to defaults. Commit `581f77e` added a second guard:

> A truncating in-place write (shell redirection and similar) can be observed mid-save as a valid-but-incomplete TOML that parses to defaults and would reset the running config — shrinking workspaces and relocating windows. Requiring mtime stability across two consecutive polls skips that transient; editors that atomic-save were already safe.

So the reload condition is: **mtime advanced AND stable across two consecutive polls.** Atomic-saving editors (most GUI editors, `cp` to a temp + rename) never trip this; only in-place truncating writes do, and they only lose one poll cycle.

### Status-bar staleness

A hot-reloaded workspace count now updates the status-bar workspace menu. Before `581f77e`, `setWorkspaceCount` ran only at startup, so changing the workspace count in config left the menu stale after a reload. If you add a config option that affects a UI surface, wire it into `applyConfig` and the status bar.

## Deferred startup until Accessibility is granted (commit `b49976b`)

Tiler cannot function without Accessibility access. The original launch guard showed the system grant-accessibility dialog and then called `NSApplication.shared.terminate(nil)`, forcing a manual relaunch after the user granted permission. The fix:

> Show the dialog; keep running in degraded mode. A 2 s poll timer reads `AXIsProcessTrusted()` (no re-prompt) and runs the normal startup sequence on the first grant. The startup body is extracted into `startCore()` guarded by `windowManager == nil` so a duplicate timer fire cannot double-start.

The pattern: **prompt once, poll silently, defer the capability start to the false→true transition.** `AXIsProcessTrusted()` with no re-prompt is polled rather than re-showing the dialog, so the user only sees the prompt once. The `windowManager == nil` guard is essential because the poll timer can fire multiple times before the grant and once after — without it, the first grant would start Tiler twice.

A degraded-mode status bar (commit `d440e0b`) shows the user that Tiler is waiting for permission rather than appearing broken.

## State persistence and crash recovery (commits `0f93e9a`, `dc13635`)

State persistence is straightforward: every state mutation writes `~/Library/Application Support/tiler/state.json`, and on launch the saved workspaces, columns, and widths are restored. The subtlety is what happens to windows Tiler has parked off-screen on inactive workspaces when Tiler exits unexpectedly.

On a clean quit, `gatherWindowsToMainScreen()` runs from `applicationWillTerminate` before `saveState` — partially visible windows snap to the nearest edge of the main screen's visible frame, non-visible windows are centered, and windows already on the main screen are left alone.

On a crash, no `applicationWillTerminate` fires, so windows from inactive workspaces are left parked off-screen (a 1px sliver at the screen edge). Commit `dc13635` added crash recovery:

> On each retile, write managed window PIDs to a crash recovery file. Install signal handlers for common crash signals (SIGSEGV, SIGABRT, etc.) that posix_spawn a fresh TilerApp process with `--crash-recovery`, which reads the file and repositions stranded windows. On clean shutdown, delete the recovery file so the next launch doesn't mistake a quit for a crash. On next launch, if the file exists, perform crash recovery before starting normal operation as a fallback.

If you change the parking logic or the quit path, keep `gatherWindowsToMainScreen()` and the crash-recovery file in sync — a window stranded off-screen is the worst user-visible failure mode because the user has no way to know it's there.

## File locations

- Config: `~/.config/tiler/config.toml` (example at `Resources/config.toml.example`)
- State: `~/Library/Application Support/tiler/state.json`
- Crash recovery file: written per-retile, deleted on clean shutdown

Never edit `Package.resolved` by hand — regenerate with `swift package update`.