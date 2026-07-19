# Focus

Tiler tracks which window is focused so navigation and retile target the right tile. This topic spans three stages: the AX focus notification ([../architecture/05-ax.md](../architecture/05-ax.md)) that fires only on a subset of real focus changes, the shell's pre-reducer focus sync ([../architecture/03-windowmanager.md](../architecture/03-windowmanager.md)), and the reducer's focus-index clamping ([../architecture/02-reducer.md](../architecture/02-reducer.md)). The AX notification covers only a subset of real focus changes, and the notification itself can fail to resolve to a CG ID, so focus is re-derived from several sources. This page lists each gap and the compensation for it.

## Notification gap

`kAXFocusedWindowChangedNotification` does not fire for:

- **Cmd+Tab to an already-running app** — focus moves to the app's frontmost window; no intra-app change occurs.
- **Clicking a window in another app** — the cross-app change is not reported as an intra-app event.

Without compensation, tiled focus indices go stale and the next h/j/k/l acts on the wrong window.

## 1. App activation sync

Cmd+Tab and cross-app clicks are covered by `NSWorkspace` activation notifications, which re-derive focus from the now-frontmost app.

`NSWorkspace.didActivateApplicationNotification` fires when an app becomes frontmost. Tiler re-derives the tiled focus from the frontmost app's `kAXFocusedWindowAttribute`, superseding stale pending focus and queuing a replay when the window is not tiled yet. A startup sync runs once because no activation notification fires for the already-frontmost app.

## 2. Re-derive on notification-element failure

When the focus notification fires but its element will not resolve to a CG ID, focus is re-derived from the app's `kAXFocusedWindowAttribute`.

When the notification fires but its element does not resolve to a CG ID (`_AXUIElementGetWindow` fails transiently), `handleFocusChanged` re-derives the focused window from `kAXFocusedWindowAttribute`. The resolved element is carried forward for screen detection and pending replay, so a stale notification element does not leave `focusedScreenID` on the wrong screen.

## 3. syncFocusedScreenFromAX before navigation

Every navigation action re-reads the focused window's screen from AX, so a click on another monitor routes the keystroke to the right screen.

Before each navigation action, `syncFocusedScreenFromAX` reads the frontmost app's focused window and updates `focusedScreenID`:

```swift
private func syncFocusedScreenFromAX() { /* reads kAXFocusedWindowAttribute */ }
```

It runs at the top of action dispatch (`WindowManager.swift:1245`, `:1589`). This catches a user click on another screen that produced no focus notification; without it, h/l/j/k route to the screen Tiler last knew about.

## 4. Multi-monitor

Focus-dependent actions target the screen of the focused window, not `NSScreen.main`, because a menu-bar app always reports the primary screen.

Tiler is a menu-bar app; `NSScreen.main` always returns the primary screen. Focus-dependent reducer actions operate on the monitor where the focused window lives, tracked via `focusedScreenID` from AX focus events and used in `activeScreenID()` and `screenID(for:)`. A `minY` tiebreaker in `visibleFrame.minX` screen sorts gives deterministic ordering for vertically stacked monitors after wake/sleep. Screen actions are named `previous`/`next` (cyclic), not `left`/`right`.

## 5. Replay dropped focus events

A focus event for a window not yet tiled is queued and replayed once the window enters the tile set.

A focus event for a not-yet-tiled window cannot update focus indices. Tiler queues a deferred replay that re-attempts the sync once the window is in the tile set. The activation sync also queues replays for not-yet-tiled windows.

## 6. Clamp stale focusedWindowIndex

When tabs are reaped from a column, the focused-window index is clamped so a persisted stale value self-heals instead of silently skipping the AX raise.

When tabs are reaped from a `.tab` column, the column survives with a shorter `windows` array; `focusedWindowIndex` could point past the end. `focusFocusedWindow` then hit `guard focusedWindowIndex < windows.count` and returned, skipping the AX raise — keyboard focus stayed put while `focusedColumnIndex` targeted the column. The LayoutEngine masked it by clamping with `min(focusedWindowIndex, count - 1)`, so the window looked focused while the raise was skipped.

The fix clamps `focusedWindowIndex` in the reconcile and `removeWindowsForPID` paths whenever a column survives reaping with windows remaining, and makes `focusFocusedWindow` clamp-and-continue so a stale persisted index self-heals.