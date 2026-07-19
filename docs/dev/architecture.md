# Architecture

Tiler's runtime is split into a pure core that decides what the layout should be and an impure shell that makes it so by talking to macOS. Data flows one way:

```
State  ──▶  Action  ──▶  Reducer  ──▶  [Effect]  ──▶  Shell  ──▶  AX/CG  ──▶  (observed again)
  ▲                                                                  │
  └──────────────────── state mutation only inside the reducer ◀──────┘
```

Vocabulary used below is defined in [README.md](README.md#concepts-and-vocabulary). This page covers the five parts in order, then the runtime mechanics that connect them.

## State

**What it is:** `TilerState`, a tree of plain Swift value types (`struct`) describing every managed window and its placement.

**What it holds:**

```
TilerState
└─ screens: [ScreenID: ScreenState]
   └─ activeWorkspaceID, info (frame, visibleFrame)
   └─ workspaces: [WorkspaceID: Workspace]
      └─ focusedColumnIndex, scrollOffset
      └─ columns: [Column]
         └─ mode (.stack | .tab), widthFraction, focusedWindowIndex,
            measuredMinWidth?, measuredMinHeight?
         └─ windows: [WindowNode]
            └─ id: CGWindowID, groupKey: GroupKey, pid, title
```

**How data is handled:** everything is a value type, so a mutation is a copy-and-replace. `State` carries no handles to the outside world — no `AXUIElement`, no file descriptors, no timers. Those live in the shell. State is the single source of truth for layout; the shell never holds a parallel model of where windows are.

## Action

**What it is:** an `Action` enum value describing an intent, e.g. `.focusColumnLeft`, `.focusWorkspace(3)`, `.consumeOrExpelRight`, `.closeWindow`.

**Where it comes from:**

- Hotkey presses (Carbon) → `Action` via the keybind parser.
- System events: `AXObserver` notifications and `NSWorkspace` notifications, plus the periodic `CGWindowList` reconcile pass, are translated into `Action` values by the shell.

An `Action` says *what the user or system wants*, not *how to do it*. It carries no state of its own beyond its arguments (e.g. the workspace index).

## Reducer

**What it is:** a pure static function:

```swift
enum Reducer {
  static func apply(
    _ action: Action,
    to state: inout TilerState,
    env: ReducerEnv
  ) -> [Effect]
}
```

**What it does:** given an action and the current state, it mutates `state` in place and returns a list of `Effect` values describing the side-effects the shell should perform. All layout decisions — which column is focused, where a moved window lands, how widths change — happen here.

**How data is handled — the purity contract:**

- No I/O, no AX, no CG, no filesystem, no timers. The reducer never observes the outside world; it only reads `state` and `env`.
- `ReducerEnv` carries read-only inputs the reducer needs to make decisions — `workspaceCount`, `activeScreenID`, `orderedScreenIDs`, `focusColumnWrap`. It never carries live handles.
- Determinism: the same `(action, state, env)` always yields the same new state and effects.

Rationale: `Tests/TilerCoreTests/` constructs a `TilerState`, applies actions, and asserts on the resulting state and effects with no AX or CG access. Column math, viewport scrolling, and focus-clamping bugs are reproducible without launching the app. The suite has 80 pure-data tests.

## Effect

**What it is:** an `Effect` enum value — a description of a side-effect, not its execution.

```swift
enum Effect: Equatable {
  case retile
  case focusFocusedWindow(ScreenID, WorkspaceID)
  case raiseTabbedWindows(ScreenID, WorkspaceID)
  case closeWindow(CGWindowID)
  case toggleFullscreen(CGWindowID)
  case refreshTabs(ScreenID, WorkspaceID)
  case scheduleDeferredTabRefresh(ScreenID, WorkspaceID)
  case log(String)
}
```

**What it does:** the reducer returns a list of these instead of acting. `.retile` asks the shell to recompute and write frames; `.focusFocusedWindow` asks it to raise a window via AX; `.closeWindow` asks it to press the window's close button; `.log` asks it to emit a log line. Effects are `Equatable` so tests can assert on them.

**How data is handled:** an effect carries only the identifiers needed to perform it (a `CGWindowID`, a screen/workspace pair, a string). It does not carry `AXUIElement` handles — the shell resolves those from `WindowStore` at execution time (see [window-identity.md](window-identity.md)). This keeps the reducer free of live references and lets effects be compared in tests.

## Shell

**What it is:** `WindowManager`, the impure orchestrator. It owns the live `TilerState`, the `WindowStore`, timers, observers, and the AX/CG bridge.

**What it does:**

1. Receives events and translates them into `Action` values.
2. Runs the reducer and executes the returned effects.
3. Runs the drain loop (retile + frame corrector) until layout converges.
4. Runs the reconcile loop to discover and reap windows.
5. Persists state to disk and reloads config.

**How data is handled — the dispatch entry point:**

```swift
public func handleAction(_ action: Action) {
  syncFocusedScreenFromAX()                       // read live AX focus first
  let effects = Reducer.apply(action, to: &state, env: computeEnv())
  runEffects(effects)                             // perform side-effects
  needsSave = true                                // state changed → persist
}
```

The shell reads the outside world *before* the reducer (`syncFocusedScreenFromAX` corrects `focusedScreenID` from AX so navigation targets the right screen) and *after* it (`runEffects` acts on the results). The reducer itself stays pure. `runEffects` is a switch over `Effect` that turns each case into AX/CG calls, e.g. `.closeWindow` resolves the element from `WindowStore` and presses its close button:

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

Retile requests are coalesced: a burst of AX events produces one layout pass, not one per event. Two flags gate the work:

```swift
private var needsRetile = false
private var drainScheduled = false
```

`setNeedsRetile()` sets `needsRetile` and schedules one drain pass. The drain pass recomputes layout from `TilerState`, writes frames, then runs `reconcilePendingFrames()` (the corrector), repeating until `needsRetile` is false. This merges a burst of events (a tab swap firing several notifications, or Cmd+N spawning several windows) into a single retile.

## Convergence model

AX frame writes are not transactional. The shell sets `AXPosition` then `AXSize`; macOS clamps position based on the current size, so position is reapplied after the resize (see `applyOne` in `AXWindowBridge`). A user drag produces a geometry-changed notification indistinguishable from the echo of the shell's own write; the convergence model distinguishes them.

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

The record is written before the frame is applied (`WindowManager.swift:2038`), so the echoing AX notification matches a record. `epoch` discards records from superseded retiles — only records with `record.epoch == applyEpoch` are actionable.

### Echo vs genuine move

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

- `absorbMinWidth` / `absorbMinHeight` — record the window's real minimum as `column.measuredMinWidth` and retile to honor it; the next `framesMatch` succeeds.
- accept the settled frame — when the window landed smaller than requested, rewrite the echo reference to the observed frame so the snap-back path does not re-issue a frame the window cannot reach.

`absorbMinWidth` skips absorption at screen width — see [screen-lifecycle.md](screen-lifecycle.md).

Re-issues are batched into one `AXWindowBridge.applyFrames` call per drain, so the `AXEnhancedUserInterface` toggle fires once per app — see [ax-integration.md](ax-integration.md).

### Reaping

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

`reapingAllowed` suppresses reaping during unreliable passes — see [screen-lifecycle.md](screen-lifecycle.md).

## See also

- [window-identity.md](window-identity.md) — how the shell resolves `CGWindowID` ↔ `AXUIElement` when running effects.
- [window-filtering.md](window-filtering.md) — what enters the tile set during reconcile.
- [native-tabs.md](native-tabs.md) — why effects are keyed by `GroupKey`, not `CGWindowID`.
- [focus.md](focus.md) — the AX reads the shell does before the reducer.
- [screen-lifecycle.md](screen-lifecycle.md) — when reaping is suppressed.
- [ax-integration.md](ax-integration.md) — how the shell writes frames.
- [config-and-startup.md](config-and-startup.md) — config reload and startup.