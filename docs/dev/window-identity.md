# Window identity

Tiler tracks windows by `CGWindowID` (a CoreGraphics identifier) and acts on them through `AXUIElement` (Accessibility). The two namespaces are not linked by a public API, and the private bridge that links them fails transiently. `WindowStore` maintains the mapping.

## Sources

- `CGWindowListCopyWindowInfo` — windows the system composites, keyed by `kCGWindowNumber` (`CGWindowID`), with owner PID, layer, bounds, and title.
- `AXUIElementCreateApplication(pid).kAXWindowsAttribute` — the app's AX windows; the handles Tiler can move, focus, and close.

CG lists overlays and menu-bar layers; AX omits windows whose role has not appeared yet. `axGetWindowID` (the private SPI mapping an AX element to a CG ID) fails transiently.

## axGetWindowID and position fallback

Each AX window is matched to a CG ID first by the private `axGetWindowID` SPI, then by position as a fallback. First match attempt:

```swift
if let foundWid = axGetWindowID(axWindow) {
  elements[foundWid] = axWindow
  matchedCG.insert(foundWid)
}
```

`axGetWindowID` (`AXPrivate.swift`) is resolved at runtime via `dlsym`; if Apple removes the symbol it returns nil rather than crashing. On nil, the store falls back to position and size matching against the CG list with a 20-point tolerance.

### Multi-window ambiguity

The position fallback runs only when the PID has at most one AX window:

```swift
// Position-heuristic fallbacks are only safe when there's at most one AX window
// for this pid. With multiple windows, heuristics can silently swap identities
// while a window is mid-move, causing frames to be applied to the wrong element.
let allowPositionFallback = axWindows.count <= 1
```

Two windows briefly share a frame during a drag. With multiple AX windows per PID, position matching can bind a CG ID to the wrong AX element, and a frame write moves the wrong window. The guard skips the window; it is picked up when `axGetWindowID` succeeds.

## Orphan pass

Windows present in CG but unresolved to an AX element are orphans — usually a window whose AX role has not appeared. A separate pass adopts them by position. The orphan pass subtracts `storedWids` from all CG IDs (before the layer filter); subtracting only from layer-≤-0 CG IDs would treat overlay windows at layer > 0 as missing orphans and re-admit them.

## Exponential backoff

`tryPositionResolve` scans the app's AX windows for an unmapped element at a CG frame. Running it on every reconcile for every no-element window hammers AX during event storms (Amethyst #1766 class). A backoff map bounds the retries:

```swift
private var noElementRetry: [CGWindowID: (attempts: Int, nextAttemptAt: Date)] = [:]
```

Each failure doubles the delay, capped at 5s. The periodic poll reconcile still guarantees eventual resolution; resolved or gone windows drop out of the retry map.

## Ambiguity refusal

`tryPositionResolve` returns nil when more than one unmapped AX window sits at the target frame:

```swift
// Ambiguous — more than one candidate at this position
guard matched == nil else { return nil }
```

A deferred resolution is safer than a wrong binding; the reconcile loop retries.

## liveElement

The cached map can be stale immediately after a native tab switch. `liveElement(forPID:wid:)` re-scans the app's AX windows and matches by `axGetWindowID`:

```swift
public func liveElement(forPID pid: pid_t, wid: CGWindowID) -> AXUIElement? {
  // AXUIElementCreateApplication(pid).kAXWindowsAttribute
  for axWindow in axWindows {
    if axGetWindowID(axWindow) == wid { return axWindow }
  }
  return nil
}
```

`resolveActiveTabSwap` (see [native-tabs.md](native-tabs.md)) uses this as a fallback when the store lacks the active tab's element.

## windowIDByIdentity

During `kAXUIElementDestroyedNotification` the element may be partially torn down and `axGetWindowID` fails. `windowIDByIdentity` falls back to pointer equality against stored elements so the CG ID can still be found for reaping:

```swift
public func windowIDByIdentity(for element: AXUIElement) -> CGWindowID? {
  for (wid, stored) in elements where stored === element { return wid }
  return nil
}
```

## Failure mode

Identity errors do not crash; they mis-target — a frame write moves an unrelated window, or a reap drops a window that is still open. The multi-window fallback gate, ambiguity refusal, backoff, and live rescan all preserve a refuse-rather-than-guess posture. Preserve it when modifying this file.