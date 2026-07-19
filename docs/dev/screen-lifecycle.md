# Screen lifecycle: lock, reconfiguration, and the fullscreen trap

Three distinct problems live in this area: the post-lock mass-reap that wiped workspaces, the display-reconfiguration storm on wake, and the fullscreen-exit bug that permanently locked a column at screen width. They share a theme — AX/CG give us transient, unreliable information during display transitions, and acting on it naively destroys state.

## Screen lock/unlock: suppressing reaping (commit `5f340c0`)

When the screen locks, every managed window vanishes from the on-screen `CGWindowList` (the lock screen takes over). A naive reconciler treats this as "every window closed" and reaps the lot — wiping workspace assignments and column layout the instant the user locks their screen.

The fix has four parts:

1. **`reapingAllowed` flag in `reconcilePlan`.** When false, skip missing-count increments and reaping entirely:

```swift
public func reconcilePlan(
  ...
  reapingAllowed: Bool = true
) -> ReconcilePlan {
  ...
  if reapingAllowed {
    counts[id, default: 0] += 1
    if counts[id]! >= missThreshold { toReap.insert(id) }
  }
}
```

2. **Suppress reaping across lock + 3s after unlock.** Lock sets `reapSuppressedUntil = .distantFuture` and stops the reconcile timer; unlock clears `missingCounts` and sets `reapSuppressedUntil = now + 3.0`:

```swift
private func screenDidUnlock() {
  missingCounts.removeAll()
  reapSuppressedUntil = Date(timeIntervalSinceNow: 3.0)
  ...
}
```

Clearing `missingCounts` on unlock is the subtle part — lock-time miss counts must not carry over into the first live pass, or windows would still reap from counts accumulated while locked.

3. **Mass-disappearance guard.** Even outside lock, if `managedIDs` is non-empty but `stillAlive` is empty, the pass is unreliable — treat it as such and skip reaping with a 1s deferred retry. This catches display sleep and other transient "everyone vanished" states.

4. **Wall-clock miss debounce.** The miss threshold (`missThreshold = 2`) counted two passes, which on a fast machine is milliseconds. The `hasPendingMiss` retrigger was changed from a synchronous `setNeedsReconcile()` to a 0.5s token-coalesced deferred dispatch, so the debounce has wall-clock protection instead of counting two passes in milliseconds.

If you add a new "windows vanish" scenario, it belongs behind `reapingAllowed` or the mass-disappearance guard, not as a new reap path.

## Display reconfiguration debounce (commit `ba98c0c`)

`NSApplication.didChangeScreenParametersNotification` fires when displays change. macOS Tahoe can fire it repeatedly with stale geometry on wake — a CG bug. Acting on each notification thrashes the screen map and can adopt transient incorrect frames:

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

A trailing 0.5s coalescing timer: each notification bumps the token and schedules a deferred `reconfigureScreens`; only the last notification in a burst takes effect, and only after `NSScreen.screens` has settled. The token guard is the standard pattern for "cancel any pending earlier invocation."

## The fullscreen min-width trap (commit `fb025fb`)

This is the bug `absorbMinWidth`'s guard exists for. When a window enters native fullscreen, its width becomes the full screen width. The frame corrector sees a window that "won't shrink" to its tiled width and calls `absorbMinWidth` with the fullscreen width, which records it as `measuredMinWidth` — permanently locking the column at screen width even after the window exits fullscreen.

### Guard 1: skip absorption at screen size

```swift
let usableWidth = LayoutGeometry.usableWidth(screenState.info, gaps)
guard observedWidth < usableWidth else {
  tiler_debug("absorbMinWidth: skipping \(observedWidth) >= usable \(usableWidth) (likely fullscreen transition)")
  return
}
```

A genuine minimum width can never approach the usable screen width — that would mean the window fills the entire tiling area, which only happens during a fullscreen transition. `absorbMinHeight` has the same guard for height.

### Guard 2: `wasNotTileableLastPass` stickiness and reset

The guard above has timing windows — absorption can happen before the fullscreen transition is detected, or the guard's timing can miss. The second defense is the sticky not-tileable set:

```swift
let becameTileable = tileableIDs.intersection(wasNotTileableLastPass)
if !becameTileable.isEmpty {
  // reset measuredMinWidth / measuredMinHeight for their columns
}
```

When a window transitions from not-tileable (fullscreen, minimized) back to tileable, its column's `measuredMinWidth`/`measuredMinHeight` are reset and a retile is queued. The not-tileable set is kept **sticky** — a fullscreen window may vanish from `CGWindowList` for several reconcile passes during the Space transition, and we need to remember it was not-tileable until it returns as tileable or is reaped:

```swift
wasNotTileableLastPass = (wasNotTileableLastPass.union(notTileableCandidates))
  .intersection(managedIDsAfterReap)
  .subtracting(tileableIDs)
```

The set is unioned with this pass's not-tileable candidates, intersected with still-managed IDs (drop reaped), and minus currently-tileable IDs (drop recovered). Without stickiness, a window that flickers out of `CGWindowList` mid-fullscreen would be forgotten and re-added from scratch, losing its column.

## Why all three are here together

Lock, wake, and fullscreen are the three moments AX/CG lie to us. The design rule across all three: **when the information is known to be unreliable, don't mutate durable state.** Suppress reaping, debounce reconfiguration, refuse to absorb a min-width that's clearly a transient. Recovery is always possible on the next reliable pass; a wrong durable mutation is not.