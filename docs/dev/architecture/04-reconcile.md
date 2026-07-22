# 04 — Reconcile

The reconcile loop is the shell's input side. It discovers windows from `CGWindowList` and AX, filters which are tileable, resolves `CGWindowID` ↔ `AXUIElement` identities through a transient private bridge, adopts orphans, and suppresses reaping when observations are unreliable. It runs on a periodic poll and is the backstop for events missed by `AXObserver` ([05-ax.md](05-ax.md)).

## Window filtering

`WindowFilter.isTileable(_:)` decides whether a discovered window enters the tile set. The check is a pipeline of guards applied in order: role, subrole with a close-button requirement, minimized, fullscreen, and owner activation policy. Each guard exists because a real app exposed a case the previous check admitted or rejected incorrectly.

### Checks, in order

The guards run in this order; the first failure rejects the window.

```swift
public static func isTileable(_ element: AXUIElement) -> Bool {
  // 1. Role: AXWindow, or AXTextField (Emacs — see below)
  // 2. Subrole: reject AXSheet/AXDrawer/AXSystemDialog/AXFloatingWindow/Quick Look;
  //    AXStandardWindow and all other subroles require a close button
  // 3. Not minimized
  // 4. Not fullscreen
  // 5. Owner app activation policy .regular
}
```

### Role: the Emacs exception

The role must be a window role; Emacs is the one accepted exception because its NS port reports the main window as `AXTextField`.

The role must be `kAXWindowRole`. `AXTextField` is also accepted: Emacs's NS port reports its main window with role `AXTextField`. This is safe because `kAXWindowsAttribute` returns only window-level elements; a text field inside another app's window never reaches this function.

### Subrole

The subrole narrows which window types are accepted. A reject list excludes sheets and panels outright; every other subrole, including `AXStandardWindow`, must present a close button.

```swift
switch subroleStr {
case "AXSheet", "AXDrawer", "AXSystemDialog", "AXFloatingWindow", "Quick Look":
  return false
case "AXStandardWindow":
  // require a close button
default:
  // AXDialog, AXUnknown, etc. — require a close button
}
```

`AXSheet` is a save/open sheet attached to a window. `AXFloatingWindow` is a floating panel (color picker, Fonts panel). `Quick Look` is the subrole string Finder's space-bar preview uses. These are rejected outright. All other subroles, including `AXStandardWindow`, require a close button:

```swift
guard
  AXUIElementCopyAttributeValue(
    element, kAXCloseButtonAttribute as CFString, &closeButton
  ) == .success, closeButton != nil
else { return false }
```

### The close-button rule

The close-button check is the durable rule because macOS promotes more window types to `AXStandardWindow` over time than the subrole string can enumerate.

macOS Open/Save panels promoted to standalone windows report `AXStandardWindow` but lack a close button; tiling them would let `closeWindow` fail to close them. Chromium extension popups have `AXUnknown` subrole and no window buttons but pass the default case. The durable rule is the close-button check — macOS promotes more windows to `AXStandardWindow` over time, so checking for chrome is more robust than checking the subrole string.

`AXDialog` is tileable only with a close button: chrome-bearing dialogs are legitimate; chrome-less popups such as the Telegram attachment menu are filtered out.

### Minimized and fullscreen

Minimized and fullscreen windows are filtered out here and remembered as not-tileable so they can be restored when they return.

Minimized windows are filtered here; the reconcile loop reaps them and `wasNotTileableLastPass` remembers them so unminimizing restores the column (see [03-windowmanager.md](03-windowmanager.md#wasnottileablelastpass-reset)). Fullscreen windows are also filtered. `WindowFilter.isFullscreen` separately detects native fullscreen (dedicated Space) so the reconciler treats an absent window as hidden on its Space, awaiting return.

### Activation policy

Only `.regular` apps are tiled.

```swift
guard let app = NSRunningApplication(processIdentifier: pid),
  app.activationPolicy == .regular
else { return false }
```

Apps with `.accessory` or `.prohibited` policy are skipped.

### Modifying the filter

- Reject anything macOS promotes to `AXStandardWindow` via the close-button check.
- Accepting a new role or subrole requires a real-app justification (as for Emacs) and confirmation that `kAXWindowsAttribute` scoping makes it safe.
- Verify against the safe test apps ([../README.md](../README.md)): Finder exercises tabs and dialogs; Calculator exercises small rigid windows.

## Window identity

Tiler tracks windows by `CGWindowID` (a CoreGraphics identifier) and acts on them through `AXUIElement` (Accessibility). The two namespaces have no public API linking them, and the private bridge that links them fails transiently. `WindowStore` maintains the mapping.

### Sources

Tiler consumes two window listings and bridges them: CG's composited window list (the source of `CGWindowID`s) and each app's AX windows (the handles it can move, focus, and close).

- `CGWindowListCopyWindowInfo` — windows the system composites, keyed by `kCGWindowNumber` (`CGWindowID`), with owner PID, layer, bounds, and title.
- `AXUIElementCreateApplication(pid).kAXWindowsAttribute` — the app's AX windows; the handles Tiler can move, focus, and close.

CG lists overlays and menu-bar layers; AX omits windows whose role has yet to appear. `axGetWindowID` (the private SPI mapping an AX element to a CG ID) fails transiently.

### axGetWindowID and position fallback

An AX window is matched to a CG ID first by a private SPI, then by position; the position fallback is gated to single-window apps to avoid silent identity swaps.

```swift
if let foundWid = axGetWindowID(axWindow) {
  elements[foundWid] = axWindow
  matchedCG.insert(foundWid)
}
```

`axGetWindowID` (`AXPrivate.swift`) is resolved at runtime via `dlsym`; removing the Apple symbol degrades it to nil, never a crash. On nil, the store falls back to position and size matching against the CG list with a 20-point tolerance.

The position fallback runs only when the PID has at most one AX window:

```swift
// Position-heuristic fallbacks are only safe when there's at most one AX window
// for this pid. With multiple windows, heuristics can silently swap identities
// while a window is mid-move, causing frames to be applied to the wrong element.
let allowPositionFallback = axWindows.count <= 1
```

Two windows briefly share a frame during a drag. With multiple AX windows per PID, position matching can bind a CG ID to the wrong AX element, and a frame write moves the wrong window. The guard skips the window; it is picked up when `axGetWindowID` succeeds.

### Orphan pass

Windows seen by CG but not yet by AX are adopted by a position-matching pass that excludes already-managed IDs.

Windows present in CG but unresolved to an AX element are orphans: a window whose AX role has yet to appear. A separate pass adopts them by position. The orphan pass subtracts `storedWids` from all CG IDs (before the layer filter); subtracting only from layer-≤-0 CG IDs would treat overlay windows at layer > 0 as missing orphans and re-admit them.

### Exponential backoff

Position resolution is rate-limited so an event storm of unresolved windows keeps AX load bounded.

`tryPositionResolve` scans the app's AX windows for an unmapped element at a CG frame. Running it on every reconcile for every no-element window hammers AX during event storms (Amethyst #1766 class). A backoff map bounds the retries:

```swift
private var noElementRetry: [CGWindowID: (attempts: Int, nextAttemptAt: Date)] = [:]
```

Each failure doubles the delay, capped at 5s. The periodic poll reconcile still guarantees eventual resolution; resolved or gone windows drop out of the retry map.

### Ambiguity refusal

When more than one AX window sits at the target frame, resolution refuses to guess; the reconcile loop retries.

```swift
// Ambiguous — more than one candidate at this position
guard matched == nil else { return nil }
```

A deferred resolution is safer than a wrong binding; the reconcile loop retries.

### liveElement

A cached element lookup can be stale right after a tab switch; `liveElement` re-scans the app's AX windows to find the current handle.

```swift
public func liveElement(forPID pid: pid_t, wid: CGWindowID) -> AXUIElement? {
  // AXUIElementCreateApplication(pid).kAXWindowsAttribute
  for axWindow in axWindows {
    if axGetWindowID(axWindow) == wid { return axWindow }
  }
  return nil
}
```

`resolveActiveTabSwap` ([../topics/native-tabs.md](../topics/native-tabs.md)) uses this as a fallback when the store lacks the active tab's element.

### windowIDByIdentity

During element destruction the SPI mapping may fail; pointer equality against stored elements recovers the CG ID for reaping.

During `kAXUIElementDestroyedNotification` the element may be partially torn down and `axGetWindowID` fails. `windowIDByIdentity` falls back to pointer equality against stored elements so the CG ID can still be found for reaping:

```swift
public func windowIDByIdentity(for element: AXUIElement) -> CGWindowID? {
  for (wid, stored) in elements where stored === element { return wid }
  return nil
}
```

### Identity failure mode

Identity errors degrade to a mis-target, never a crash; every path in this file keeps a refuse-to-guess posture.

A frame write moves an unrelated window, or a reap drops a window that is still open. The multi-window fallback gate, ambiguity refusal, backoff, and live rescan all preserve that posture. Preserve it when modifying this file.

## Reaping suppression

A managed window absent from `CGWindowList` for one pass may still be present; `kAXWindowsAttribute` transiently returns fewer windows than exist. Reaping counts consecutive misses and reaps at a threshold; the mechanism lives in [03-windowmanager.md](03-windowmanager.md#reaping). Suppression flags below keep that mechanism from firing on transient disappearances.

### Mass disappearance

The primary guard, run every reconcile pass. The pure predicate `massDisappearanceActive` (`Reconcile.swift`) decides whether managed windows are vanishing from a system transition rather than genuine closure, and `reconcile()` skips reaping for that pass with a 1s deferred retry:

```swift
let massDisappearance = massDisappearanceActive(
  managedIDs: managedIDs, stillAliveIDs: stillAlive, onScreenIDs: onScreenIDs)
```

The signal is managed windows still *composited* (in `onScreenIDs`) but with *no live AX element* this pass — `managedIDs` minus `stillAliveIDs`, intersected with `onScreenIDs`. Genuine closure removes a window from `CGWindowList`, so it drops out of that set; a window that keeps its CG entry but loses its element is AX-suspended, not closed.

- **Display-wake lag** — `onScreenIDs` empty: `CGWindowList` returned nothing on screen while managed windows exist. The scan hasn't caught up to reality.
- **Screen saver / display sleep** — the AX server is suspended, so every managed window loses its AX element at once, yet `CGWindowList` still reports them.
- **Another app's fullscreen Space** (e.g. mpv) — the off-Space windows lose their AX element and drop out of `stillAlive`, but `CGWindowList` still composites them; the fullscreen app itself stays alive. Reaping here would discard every column assignment and width, since the next pass re-adds the windows as fresh columns on the active workspace.

Two or more AX-suspended windows trigger suppression; a lone one is left to the no-element backoff. When no managed window is alive but at least one is still composited, that straggler is treated as full suspension too — the scan is partially working but AX isn't.

This guard is what protects the layout during the gap between the screen saver blanking the display — when AX elements vanish — and the `com.apple.screenIsLocked` notification arriving (which fires after the elements are already gone), and during an app's fullscreen Space, which fires no lock notification at all. The lock observers below extend the suppression across the rest of the locked interval.

### Lock/unlock

A secondary signal: the lock/unlock observers suppress reaping across the lock and for a grace period after unlock, and pause the periodic poll so a late reconcile during the locked interval can't reap either.

1. `reapingAllowed` flag in `reconcilePlan`:

```swift
if reapingAllowed {
  counts[id, default: 0] += 1
  if counts[id]! >= missThreshold { toReap.insert(id) }
}
```

2. Lock sets `reapSuppressedUntil = .distantFuture` and stops the reconcile timer; unlock clears `missingCounts` and sets `reapSuppressedUntil = now + 3.0`:

```swift
private func screenDidUnlock() {
  missingCounts.removeAll()
  reapSuppressedUntil = Date(timeIntervalSinceNow: 3.0)
  ...
}
```

Clearing `missingCounts` on unlock prevents lock-time miss counts from carrying into the first live pass.

3. Wall-clock miss debounce: the `hasPendingMiss` retrigger is a 0.5s token-coalesced deferred dispatch. The miss threshold (`missThreshold = 2`) counted two passes, which on a fast machine is milliseconds.