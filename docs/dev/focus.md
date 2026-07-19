# Focus

`kAXFocusedWindowChangedNotification` fires only on intra-app focus changes. Cmd+Tab to a running app and cross-app clicks produce no notification, and the notification that does fire may carry an element that cannot resolve to a CG ID. Tiler compensates in several places.

## Notification gap

`kAXFocusedWindowChangedNotification` does not fire for:

- **Cmd+Tab to an already-running app** — focus moves to the app's frontmost window; no intra-app change occurs.
- **Clicking a window in another app** — the cross-app change is not reported as an intra-app event.

Without compensation, tiled focus indices go stale and the next h/j/k/l acts on the wrong window.

## 1. App activation sync

`NSWorkspace.didActivateApplicationNotification` fires when an app becomes frontmost. Tiler re-derives the tiled focus from the frontmost app's `kAXFocusedWindowAttribute`, superseding stale pending focus and queuing a replay when the window is not tiled yet. A startup sync runs once because no activation notification fires for the already-frontmost app.

## 2. Re-derive on notification-element failure

When the notification fires but its element does not resolve to a CG ID (`_AXUIElementGetWindow` fails transiently), `handleFocusChanged` re-derives the focused window from `kAXFocusedWindowAttribute`. The resolved element is carried forward for screen detection and pending replay, so a stale notification element does not leave `focusedScreenID` on the wrong screen.

## 3. syncFocusedScreenFromAX before navigation

Before each navigation action, `syncFocusedScreenFromAX` reads the frontmost app's focused window and updates `focusedScreenID`:

```swift
private func syncFocusedScreenFromAX() { /* reads kAXFocusedWindowAttribute */ }
```

It runs at the top of action dispatch (`WindowManager.swift:1245`, `:1589`). This catches a user click on another screen that produced no focus notification; without it, h/l/j/k route to the screen Tiler last knew about.

## 4. Multi-monitor

Tiler is a menu-bar app; `NSScreen.main` always returns the primary screen. Focus-dependent reducer actions operate on the monitor where the focused window lives, tracked via `focusedScreenID` from AX focus events and used in `activeScreenID()` and `screenID(for:)`. A `minY` tiebreaker in `visibleFrame.minX` screen sorts gives deterministic ordering for vertically stacked monitors after wake/sleep. Screen actions are named `previous`/`next` (cyclic), not `left`/`right`.

## 5. Replay dropped focus events

A focus event for a not-yet-tiled window cannot update focus indices. Tiler queues a deferred replay that re-attempts the sync once the window is in the tile set. The activation sync also queues replays for not-yet-tiled windows.

## 6. Clamp stale focusedWindowIndex

When tabs are reaped from a `.tab` column, the column survives with a shorter `windows` array; `focusedWindowIndex` could point past the end. `focusFocusedWindow` then hit `guard focusedWindowIndex < windows.count` and returned, skipping the AX raise — keyboard focus stayed put while `focusedColumnIndex` targeted the column. The LayoutEngine masked it by clamping with `min(focusedWindowIndex, count - 1)`, so the window looked focused while the raise was skipped.

The fix clamps `focusedWindowIndex` in the reconcile and `removeWindowsForPID` paths whenever a column survives reaping with windows remaining, and makes `focusFocusedWindow` clamp-and-continue so a stale persisted index self-heals.