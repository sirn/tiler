# Screen lifecycle

Lock, wake, and fullscreen are the moments AX and CG return transient, unreliable information. The design rule across all three: when information is unreliable, do not mutate durable state. Suppress reaping, debounce reconfiguration, refuse to absorb a min-width that is a transient.

## Lock/unlock reaping suppression

When the screen locks, every managed window vanishes from the on-screen `CGWindowList`. A naive reconciler reaps the lot, wiping workspace assignments and column layout.

1. `reapingAllowed` flag in `reconcilePlan`:

```swift
if reapingAllowed {
  counts[id, default: 0] += 1
  if counts[id]! >= missThreshold { toReap.insert(id) }
}
```

2. Suppress reaping across lock and 3s after unlock. Lock sets `reapSuppressedUntil = .distantFuture` and stops the reconcile timer; unlock clears `missingCounts` and sets `reapSuppressedUntil = now + 3.0`:

```swift
private func screenDidUnlock() {
  missingCounts.removeAll()
  reapSuppressedUntil = Date(timeIntervalSinceNow: 3.0)
  ...
}
```

Clearing `missingCounts` on unlock prevents lock-time miss counts from carrying into the first live pass.

3. Mass-disappearance guard: if `managedIDs` is non-empty but `stillAlive` is empty, the pass is unreliable; skip reaping with a 1s deferred retry. Catches display sleep and similar transients.

4. Wall-clock miss debounce: the `hasPendingMiss` retrigger changed from synchronous `setNeedsReconcile()` to a 0.5s token-coalesced deferred dispatch. The miss threshold (`missThreshold = 2`) counted two passes, which on a fast machine is milliseconds.

## Display reconfiguration debounce

`didChangeScreenParametersNotification` fires on display changes. macOS Tahoe can fire it repeatedly with stale geometry on wake. A trailing 0.5s coalescing timer:

```swift
private var screenReconfigToken: UInt64 = 0
private func scheduleScreenReconfigure() {
  screenReconfigToken &+= 1
  let token = screenReconfigToken
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
    guard let self = self, self.screenReconfigToken == token else { return }
    self.reconfigureScreens()
  }
}
```

Each notification bumps the token and schedules a deferred `reconfigureScreens`; only the last in a burst takes effect, after `NSScreen.screens` has settled.

## Fullscreen min-width guard

When a window enters native fullscreen, its width becomes the full screen width. The frame corrector sees a window that will not shrink to its tiled width and calls `absorbMinWidth` with the fullscreen width, which records it as `measuredMinWidth` — locking the column at screen width after exit.

### Guard 1: skip absorption at screen size

`absorbMinWidth` refuses values at or above the usable screen width, which only occur during a fullscreen transition.

```swift
let usableWidth = LayoutGeometry.usableWidth(screenState.info, gaps)
guard observedWidth < usableWidth else {
  tiler_debug("absorbMinWidth: skipping \(observedWidth) >= usable \(usableWidth) (likely fullscreen transition)")
  return
}
```

A genuine minimum width cannot approach the usable screen width; that value indicates a fullscreen transition. `absorbMinHeight` has the same guard.

### Guard 2: wasNotTileableLastPass reset

When a window transitions from not-tileable (fullscreen, minimized) back to tileable, its column's `measuredMinWidth` / `measuredMinHeight` reset and a retile queues:

```swift
let becameTileable = tileableIDs.intersection(wasNotTileableLastPass)
if !becameTileable.isEmpty {
  // reset measuredMinWidth / measuredMinHeight for their columns
}
```

The not-tileable set is sticky — a fullscreen window may vanish from `CGWindowList` for several passes during the Space transition:

```swift
wasNotTileableLastPass = (wasNotTileableLastPass.union(notTileableCandidates))
  .intersection(managedIDsAfterReap)
  .subtracting(tileableIDs)
```

Union with this pass's not-tileable candidates, intersect with still-managed IDs (drop reaped), subtract currently-tileable IDs (drop recovered). Without stickiness, a window flickering out of `CGWindowList` mid-fullscreen would be forgotten and re-added from scratch, losing its column.