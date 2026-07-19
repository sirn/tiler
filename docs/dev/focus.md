# Focus: keeping the right window raised across AX gaps

Focus is the part of Tiler most easily broken by AX's notification gaps. The system does not deliver a `kAXFocusedWindowChangedNotification` for every focus change that matters to us, and the notification it does deliver sometimes carries an element that can't be resolved to a CG ID. This page covers the four places we compensate.

## The notification gap

`kAXFocusedWindowChangedNotification` only fires on **intra-app** focus changes. Two common user actions produce no notification at all:

- **Cmd+Tab to an already-running app** — focus moves to that app's frontmost window, but no `kAXFocusedWindowChangedNotification` fires because focus didn't change *within* the app.
- **Clicking a window in another app** — same: the cross-app focus change is not reported as an intra-app event.

Without compensation, Tiler's tiled focus indices go stale and the next h/j/k/l acts on the wrong window.

## 1. Sync on app activation (commit `72e1691`)

`NSWorkspace.didActivateApplicationNotification` fires whenever an app becomes frontmost. We re-derive the tiled focus from the frontmost app's `kAXFocusedWindowAttribute` there:

> Sync the tiled focus from the frontmost app's focused window on activation, superseding any stale pending focus and queuing a replay when the window isn't tiled yet. Also sync once at startup, since no activation notification fires for the already-frontmost app.

This catches Cmd+Tab and cross-app clicks. The startup sync matters because the app that was frontmost when Tiler launched never sends an activation notification.

## 2. Re-derive focus when the notification element fails (commit `3d1de34`)

Even when the notification *does* fire, the element it carries may not resolve to a CG ID — `_AXUIElementGetWindow` fails transiently. `handleFocusChanged` re-derives the focused window from `kAXFocusedWindowAttribute` instead of trusting the notification element:

> handleFocusChanged now re-derives the focused window from `kAXFocusedWindowChangedNotification` when the AX notification element fails to resolve to a CGWindowID (transient `_AXUIElementGetWindow` failure). The resolved element is carried forward for screen detection and pending replay storage, so a stale notification element no longer leaves `focusedScreenID` pointing at the wrong screen.

## 3. `syncFocusedScreenFromAX` before every navigation action

This is the belt-and-suspenders fix that makes focus robust even when both notifications miss. Before each navigation action, we read the frontmost app's focused window and update `focusedScreenID`:

```swift
private func syncFocusedScreenFromAX() { /* ... reads kAXFocusedWindowAttribute ... */ }
```

It runs at the top of the action dispatch (`WindowManager.swift:1245` and `:1589`). This catches the case where the user clicked a window on another screen and no focus notification reached Tiler — without it, h/l/j/k would route to the screen Tiler last knew about, not the screen the user is actually looking at.

## 4. Multi-monitor: focus follows the window, not `NSScreen.main` (commit `e2b5db0`)

Tiler is a menu-bar app, so `NSScreen.main` always returns the primary screen — useless for deciding which monitor a focus action should target. Instead we track `focusedScreenID` from AX focus events and use it in `activeScreenID()` and `screenID(for:)`:

> Make all focus-dependent reducer actions operate on the monitor where the focused window lives, not `NSScreen.main`.

A `minY` tiebreaker was added to all `visibleFrame.minX` screen sorts so vertically stacked monitors get deterministic ordering after wake/sleep (geometry can arrive in a different order on reconfiguration). The screen actions were renamed `left/right` → `previous/next` to match their cyclic spatial semantics.

## 5. Replay dropped focus events (commit `0e3490c`)

When a focus event arrives for a window that isn't tiled yet (it was just created and the reconcile loop hasn't adopted it), we can't update focus indices — there's no node to point at. We queue a replay: a deferred retry that re-attempts the focus sync once the window is in the tile set. This pairs with the activation sync above, which also queues a replay for not-yet-tiled windows.

## 6. Clamp stale `focusedWindowIndex` after reaping (commit `194523b`)

A subtle one. When tabs are reaped from a `.tab` column, the column survives with a shorter `windows` array, but `focusedWindowIndex` could now point past the end:

> A `.tab` column whose tabs were reaped was left with `focusedWindowIndex` pointing past the now-shorter windows array. `focusFocusedWindow` then hit `guard focusedWindowIndex < windows.count` and silently returned, skipping the AX raise: keyboard focus stayed put even though `focusedColumnIndex` correctly targeted the column.

The LayoutEngine masked it because it clamps with `min(focusedWindowIndex, count - 1)`, so the window *looked* focused on screen while the AX raise was silently skipped. The fix clamps `focusedWindowIndex` in both the reconcile and `removeWindowsForPID` paths whenever a column survives reaping with windows remaining, and makes `focusFocusedWindow` clamp-and-continue rather than no-op so a stale persisted index self-heals on the next focus.

## Why all of this is here

Every clause above corresponds to a real mis-focus report. The pattern: AX says nothing, or says something about the wrong element, and Tiler silently keeps acting on the previous focus. When changing focus handling, the test is not "does the happy path focus" — it's "after Cmd+Tab, after a cross-screen click, after a window is reaped, after a not-yet-tiled focus event, is the raised window the one the user expects?" Walk the [debugging workflow](README.md) with TextEdit across two monitors to exercise these.