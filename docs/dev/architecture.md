# Architecture: the purity contract and the convergence loop

Tiler is an Elm-style system: **State → Action → Reducer → Effect → Shell**. The load-bearing rule is that the reducer is pure and every macOS API call lives in the shell. This page is a deep dive on what that contract buys us and how the shell makes AX eventually converge despite AX being lossy, asynchronous, and sometimes wrong.

## The purity contract

`Reducer.apply` is a static, side-effect-free function over value types:

```swift
enum Reducer {
  static func apply(
    _ action: Action,
    to state: inout TilerState,
    env: ReducerEnv
  ) -> [Effect]
}
```

It mutates `TilerState` (screens, workspaces, columns, window nodes — all plain value types) and returns a list of `Effect` values. It must not touch AX, CoreGraphics, the filesystem, or the network. `ReducerEnv` carries only the read-only inputs the reducer needs (config flags, focus wrap, focused screen) — never live handles.

Why this is worth the plumbing: every unit test under `Tests/TilerCoreTests/` constructs a `TilerState`, applies actions, and asserts on the resulting state and effects with no AX/CG access at all (commit `b9a3a37` introduced the pure reducer; the test suite has grown to 80 tests on pure data). A bug in column math, viewport scrolling, or focus clamping can be reproduced and fixed without launching the app.

The shell (`WindowManager`) is the only place that turns `Effect` values into real AX/CG calls, runs the drain loop, and persists state.

## The drain loop

The shell never acts on a single event immediately. Two flags coalesce work:

```swift
private var needsRetile = false
private var drainScheduled = false
```

- `setNeedsRetile()` flips `needsRetile` and schedules one drain pass on the main run loop.
- The drain pass recomputes layout, writes frames, then runs `reconcilePendingFrames()` (the corrector) — repeating until `needsRetile` is false.

This coalescing is what lets a burst of AX events (a tab swap firing three notifications, or Cmd+N spawning several windows) settle into one retile instead of N fighting retiles.

## The convergence model

AX frame writes are not transactional. We set `AXPosition` then `AXSize`; macOS clamps position based on the *current* size, so we re-apply position after the resize (see `applyOne` in `AXWindowBridge`). Meanwhile, the user can drag a window, and AX will deliver a geometry-changed notification that looks identical to the echo of our own write. The convergence model distinguishes the two.

### The `AppliedWindow` record

Every retile bumps `applyEpoch` and records the frame we asked each window to take:

```swift
private struct AppliedWindow {
  var epoch: UInt64
  var frame: NSRect
  var corrections: Int = 0
}
private var applyEpoch: UInt64 = 0
private var appliedWindows: [WindowNode.GroupKey: AppliedWindow] = [:]
```

The record is written **before** the frame is applied (`WindowManager.swift:2038`), so the AX notification that echoes our own write arrives pointing at a record it matches. The `epoch` field lets us discard records from superseded retiles — only records with `record.epoch == applyEpoch` are still actionable.

### Echo vs genuine move

`Reconcile.swift` holds the pure classifier:

```swift
public func classifyGeometryChange(observed: NSRect, applied: NSRect?, tolerance: CGFloat)
  -> EchoDecision
{
  guard let applied else { return .genuineMove }
  return framesMatch(observed, applied, tolerance: tolerance) ? .echo : .genuineMove
}
```

- `.echo` → the window reached (or is at) the frame we asked for. Clear the correction counter.
- `.genuineMove` → the window is somewhere we didn't put it. Schedule a debounced snap-back retile (`moveSettleToken`) so a user drag is corrected rather than treated as the new layout.

No recorded frame (e.g. a window we've never tiled) is treated as a genuine move — we don't want to fight a window we aren't managing.

### The bounded corrector

`reconcilePendingFrames()` re-issues frames for windows that haven't reached their target, up to three times:

```swift
if AXWindowBridge.framesMatch(observed, record.frame, tolerance: 2.0) {
  appliedWindows[gk]?.corrections = 0
} else if (appliedWindows[gk]?.corrections ?? 0) < 3 {
  appliedWindows[gk]?.corrections += 1
  reissues[wid] = record.frame
} else {
  // Budget exhausted: the window won't reach the exact frame (min-size or
  // character-cell quantization). If it's wider than desired, absorb that into
  // the column width; otherwise accept its actual settled frame as the echo
  // reference so future geometry events at this position are treated as echoes.
  if observed.width > record.frame.width + 2.0 {
    absorbMinWidth(wid: wid, observedWidth: observed.width)
  } else if observed.height > record.frame.height + 2.0 {
    absorbMinHeight(wid: wid, observedHeight: observed.height)
  } else {
    appliedWindows[gk]?.frame = observed
  }
}
```

The three-attempt budget exists because some windows physically cannot hit the requested frame: terminals are character-cell quantized, many apps have a hard minimum size. Without the budget the corrector would loop forever. The two give-up branches each prevent a different infinite loop:

- **`absorbMinWidth`/`absorbMinHeight`** — record the window's real minimum as `column.measuredMinWidth` and retile to honor it. Future frames account for the minimum, so the next `framesMatch` succeeds. This is what makes a column gracefully widen around a stubborn window.
- **accept the settled frame** — when the window landed *smaller* than requested, rewrite the echo reference to the observed frame. Otherwise the snap-back path would keep re-issuing a frame the window already can't reach.

`absorbMinWidth` has a critical fullscreen guard — see [screen-lifecycle.md](screen-lifecycle.md) for the fullscreen trap that necessitated it.

Re-issues are batched into a single `AXWindowBridge.applyFrames` call per drain so the `AXEnhancedUserInterface` toggle fires once per app rather than per window — see [ax-integration.md](ax-integration.md).

### Reaping is debounced, not immediate

A managed window disappearing from `CGWindowList` for one pass is not proof it's gone — `kAXWindowsAttribute` transiently returns fewer windows than actually exist. So reaping counts consecutive misses and only reaps at a threshold (`Reconcile.reconcilePlan`):

```swift
for id in managedIDs {
  if stillAliveIDs.contains(id) { counts[id] = 0 }
  else if reapingAllowed {
    counts[id, default: 0] += 1
    if counts[id]! >= missThreshold { toReap.insert(id) }
  }
}
```

`reapingAllowed` is the hook the screen-lock path uses to suppress reaping entirely during unreliable passes — see [screen-lifecycle.md](screen-lifecycle.md).

## Further reading

- [window-identity.md](window-identity.md) — resolving `CGWindowID` ↔ `AXUIElement`, the multi-window ambiguity guard, and orphan resolution.
- [window-filtering.md](window-filtering.md) — what makes a window tileable, and why `AXStandardWindow` alone is not enough.
- [native-tabs.md](native-tabs.md) — collapsing native tab groups to one tile with a stable identity.
- [focus.md](focus.md) — keeping focus correct across AX notification gaps and multi-monitor.
- [screen-lifecycle.md](screen-lifecycle.md) — lock/unlock, display reconfiguration, and the fullscreen min-width trap.
- [ax-integration.md](ax-integration.md) — `AXObserver` threading and the `AXEnhancedUserInterface` frame-write workaround.
- [config-and-startup.md](config-and-startup.md) — hot-reload, partial-write safety, and deferred accessibility startup.