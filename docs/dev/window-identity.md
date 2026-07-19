# Window identity: CGWindowID ↔ AXUIElement

Tiler tracks windows by `CGWindowID` (a stable CoreGraphics identifier) but acts on them through `AXUIElement` (Accessibility). These two namespaces are not linked by any public API, and the private bridge that links them fails often and silently. `WindowStore` is the module that keeps the mapping coherent. Almost every weird bug in this area traces back to one of the cases below.

## The two sources of truth

- `CGWindowListCopyWindowInfo` returns windows the system composites, keyed by `kCGWindowNumber` (`CGWindowID`), with owner PID, layer, bounds, and title. This is what tells us a window *exists* and roughly where it is.
- `AXUIElementCreateApplication(pid).kAXWindowsAttribute` returns the app's AX windows — the handles we can move, focus, and close. This is what we can *act on*.

Neither lists exactly the windows we want: CG includes overlays and menu-bar layers; AX omits windows that haven't published their AX role yet, and `axGetWindowID` (the private SPI that maps an AX element to a CG ID) fails transiently.

## `axGetWindowID` and the position fallback

The first attempt to match an AX window to a CG ID is the private SPI:

```swift
if let foundWid = axGetWindowID(axWindow) {
  elements[foundWid] = axWindow
  matchedCG.insert(foundWid)
}
```

`axGetWindowID` (`AXPrivate.swift`) is resolved at runtime via `dlsym` so the app doesn't crash if Apple removes the symbol — it just returns nil. When it returns nil we fall back to matching by position and size against the CG list, with a 20-point tolerance.

### The multi-window ambiguity guard

The position fallback is only safe when the PID has **at most one AX window**:

```swift
// Position-heuristic fallbacks are only safe when there's at most one AX window
// for this pid. With multiple windows, heuristics can silently swap identities
// while a window is mid-move, causing frames to be applied to the wrong element.
let allowPositionFallback = axWindows.count <= 1
```

Two windows briefly share a frame during a drag (the old and new positions overlap a moving window's bounds). With multiple AX windows per PID, position matching can bind a CG ID to the wrong AX element, and a frame write then moves the wrong window. The guard skips the window this pass; it will be picked up once `axGetWindowID` succeeds.

## The orphan pass and the overlay bug

Windows that appear in CG but never resolve to an AX element are "orphans" — usually a window whose AX role hasn't appeared yet. A separate pass tries to adopt them by position. Commit `9d11a6b` fixed a class of bug here:

> The AX-orphan pass subtracted `storedWids` from `cgWindowIDs` (layer ≤ 0 only), so overlay windows present in `CGWindowList` at layer > 0 were treated as missing orphans and re-admitted into tiling.

The fix tracks all CG window IDs **before** the layer filter and subtracts from that set, so windows CG already knows about at any layer are never re-evaluated as orphans.

## Exponential backoff for no-element windows

`tryPositionResolve` scans the app's AX windows for an unmapped element at a given CG frame. A window whose element isn't available yet would cause this to run on every reconcile, hammering AX during an event storm. Commit `db3f0f3` added per-window backoff:

```swift
private var noElementRetry: [CGWindowID: (attempts: Int, nextAttemptAt: Date)] = [:]
```

Each failure doubles the delay (capped at 5s) before the next attempt for that ID. The periodic poll reconcile still guarantees eventual resolution; resolved or gone windows drop out of the retry map. This is the same class of bug as Amethyst #1766.

## `tryPositionResolve` refuses ambiguity

When the fallback runs, it refuses to guess if more than one unmapped AX window sits at the target frame — ambiguity is safer than a wrong identity:

```swift
// Ambiguous — more than one candidate at this position
guard matched == nil else { return nil }
```

Returning nil leaves the window unresolved for this pass; the reconcile loop will retry. A wrong binding would silently apply frames to whichever window happened to match first.

## `liveElement` for tab swaps

The cached map can be stale immediately after a native tab switch — the AX element for the old tab is gone and the new tab's element may not be in the store yet. `liveElement(forPID:wid:)` re-scans the app's current AX windows and matches by `axGetWindowID`, giving the tab-swap path a fresh element without invalidating the whole store:

```swift
public func liveElement(forPID pid: pid_t, wid: CGWindowID) -> AXUIElement? {
  // ... AXUIElementCreateApplication(pid).kAXWindowsAttribute ...
  for axWindow in axWindows {
    if axGetWindowID(axWindow) == wid { return axWindow }
  }
  return nil
}
```

`resolveActiveTabSwap` (see [native-tabs.md](native-tabs.md)) calls this as a fallback whenever the store doesn't have the active tab's element.

## `windowIDByIdentity` for teardown races

During `kAXUIElementDestroyedNotification` the element may be partially torn down and `axGetWindowID` fails. `windowIDByIdentity` falls back to pointer equality against stored elements so we can still find the CG ID to reap:

```swift
public func windowIDByIdentity(for element: AXUIElement) -> CGWindowID? {
  for (wid, stored) in elements where stored === element { return wid }
  return nil
}
```

## Why this matters

Identity mistakes don't crash — they mis-target. A frame write to the wrong element moves an unrelated window; a reap of the wrong ID drops a window that's still open. Every guard here (the multi-window fallback gate, the ambiguity refusal, the backoff, the live rescan) exists because a previous version made one of these silent mistakes. When changing this file, preserve the "refuse rather than guess" posture.