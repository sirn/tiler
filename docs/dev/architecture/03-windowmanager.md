# 03 — WindowManager

`WindowManager` is the impure shell. It owns the live `TilerState` ([01-state.md](01-state.md)), the `WindowStore`, timers, observers, and the AX/CG bridge, and is responsible for translating events into actions, running the reducer, executing effects, and persisting state. This stage covers the dispatch entry point, the coalesced drain loop, the convergence model that distinguishes the shell's own frame writes from user drags, reaping, and the screen-lifecycle guards that keep transients from corrupting durable state.

## Dispatch entry point

The shell reads the outside world before the reducer and acts on its results after. The reducer itself stays pure.

```swift
public func handleAction(_ action: Action) {
  syncFocusedScreenFromAX()                       // read live AX focus first
  let effects = Reducer.apply(action, to: &state, env: computeEnv())
  runEffects(effects)                             // perform side-effects
  needsSave = true                                // state changed → persist
}
```

`syncFocusedScreenFromAX` corrects `focusedScreenID` from AX so navigation targets the right screen (see [../topics/focus.md](../topics/focus.md)); `runEffects` is a switch over `Effect` ([02-reducer.md](02-reducer.md)) that turns each case into AX/CG calls. For example, `.closeWindow` resolves the element from `WindowStore` and presses its close button:

```swift
case .closeWindow(let windowID):
  guard let element = windowStore.element(for: windowID) else { break }
  var closeButton: CFTypeRef?
  AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton)
  if let btn = closeButton {
    AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
  }
```

Two actions bypass the reducer entirely: `.toggleFloat` mutates a floating set the shell owns outside `TilerState`, and `.dumpFrameState` is a diagnostic. Everything else goes through `Reducer.apply`.

## Drain loop

Retile requests are coalesced so a burst of AX events produces one layout pass, not one per event. Two flags gate the work:

```swift
private var needsRetile = false
private var drainScheduled = false
```

`setNeedsRetile()` sets `needsRetile` and schedules one drain pass. The drain pass recomputes layout from `TilerState`, writes frames, then runs `reconcilePendingFrames()` (the corrector), repeating until `needsRetile` is false. This merges a burst of events (a tab swap firing several notifications, or Cmd+N spawning several windows) into a single retile.

## Convergence model

AX frame writes are not transactional, and a user drag produces a geometry-changed notification indistinguishable from the echo of the shell's own write. The convergence model tells them apart so the shell can correct its own writes without fighting the user.

The shell sets `AXPosition` then `AXSize`; macOS clamps position based on the current size, so position is reapplied after the resize (see `applyOne` in `AXWindowBridge`, [05-ax.md](05-ax.md)).

### AppliedWindow record

Each retile bumps `applyEpoch` and records the requested frame per window:

```swift
private struct AppliedWindow {
  var epoch: UInt64
  var frame: NSRect
  var corrections: Int = 0
}
private var applyEpoch: UInt64 = 0
private var appliedWindows: [WindowNode.GroupKey: AppliedWindow] = [:]
```

The record is written before the frame is applied (`WindowManager.swift:2038`), so the echoing AX notification matches a record. `epoch` discards records from superseded retiles — only records with `record.epoch == applyEpoch` are actionable. Records are keyed by `GroupKey` ([01-state.md](01-state.md#groupkey)), not `CGWindowID`, so a native-tab swap does not lose the frame.

### Echo and genuine move

A geometry change is classified by comparing the observed frame to the last frame the shell applied. The pure classifier lives in `Reconcile.swift`:

```swift
public func classifyGeometryChange(observed: NSRect, applied: NSRect?, tolerance: CGFloat)
  -> EchoDecision
{
  guard let applied else { return .genuineMove }
  return framesMatch(observed, applied, tolerance: tolerance) ? .echo : .genuineMove
}
```

- `.echo` — window is at the requested frame; clear the correction counter.
- `.genuineMove` — window is elsewhere; schedule a debounced snap-back retile (`moveSettleToken`).

No recorded frame (a window Tiler has never tiled) is a genuine move; the shell does not fight unmanaged windows.

### Bounded corrector

Windows that have not reached their target frame are re-issued, up to a bounded number of attempts. After the budget is exhausted the corrector either absorbs the window's real minimum size or accepts the settled frame. `reconcilePendingFrames()` re-issues frames up to three times:

```swift
if AXWindowBridge.framesMatch(observed, record.frame, tolerance: 2.0) {
  appliedWindows[gk]?.corrections = 0
} else if (appliedWindows[gk]?.corrections ?? 0) < 3 {
  appliedWindows[gk]?.corrections += 1
  reissues[wid] = record.frame
} else {
  if observed.width > record.frame.width + 2.0 {
    absorbMinWidth(wid: wid, observedWidth: observed.width)
  } else if observed.height > record.frame.height + 2.0 {
    absorbMinHeight(wid: wid, observedHeight: observed.height)
  } else {
    appliedWindows[gk]?.frame = observed
  }
}
```

The three-attempt budget bounds the loop: terminals are character-cell quantized and many apps have a hard minimum size. The two give-up branches each prevent an infinite loop:

- `absorbMinWidth` / `absorbMinHeight` — record the window's real minimum as `column.measuredMinWidth` ([01-state.md](01-state.md#measuredminwidth--measuredminheight)) and retile to honor it; the next `framesMatch` succeeds.
- accept the settled frame — when the window landed smaller than requested, rewrite the echo reference to the observed frame so the snap-back path does not re-issue a frame the window cannot reach.

Re-issues are batched into one `AXWindowBridge.applyFrames` call per drain, so the `AXEnhancedUserInterface` toggle fires once per app ([05-ax.md](05-ax.md#axenhanceduserinterface)).

## Reaping

A managed window absent from `CGWindowList` for one pass is not necessarily gone; `kAXWindowsAttribute` transiently returns fewer windows than exist. Reaping counts consecutive misses and reaps at a threshold (`Reconcile.reconcilePlan`):

```swift
for id in managedIDs {
  if stillAliveIDs.contains(id) { counts[id] = 0 }
  else if reapingAllowed {
    counts[id, default: 0] += 1
    if counts[id]! >= missThreshold { toReap.insert(id) }
  }
}
```

`reapingAllowed` and the suppression flags that gate it during lock, wake, and fullscreen transitions are covered in [04-reconcile.md](04-reconcile.md#reaping-suppression).

## Display reconfiguration debounce

Display-change notifications fire in bursts with stale geometry; a trailing coalescing timer applies only the final, settled configuration.

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

A window entering fullscreen briefly reports screen-width frames that must not be absorbed as a minimum width; two guards prevent the transient from locking the column.

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

### wasNotTileableLastPass reset

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