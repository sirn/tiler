# Architecture

Tiler's runtime is split into a pure core that decides what the layout should be and an impure shell that makes it so by talking to macOS. Data flows one way:

```
State  ──▶  Action  ──▶  Reducer  ──▶  [Effect]  ──▶  Shell  ──▶  AX/CG  ──▶  (observed again)
  ▲                                                                  │
  └──────────────────── state mutation only inside the reducer ◀──────┘
```

State mutation happens only inside the reducer. The shell reads the outside world before the reducer and acts on its results after, but the reducer itself is pure. This split keeps layout logic testable without AX or CG access.

The pipeline has five stages, each in its own file below. Vocabulary used across these docs is defined in [../README.md](../README.md#concepts-and-vocabulary).

## 1. [State](01-state.md)

`TilerState` is a tree of plain Swift value types describing every managed window and its placement — screens → workspaces → columns → window nodes. It is the single source of truth for layout and carries no handles to the outside world. A tile's identity is a stable `GroupKey`, not its transient `CGWindowID`.

## 2. [Reducer](02-reducer.md)

The pure core. `Reducer.apply(action, to: &state, env)` takes an `Action` and the current state and returns a new state plus a list of `Effect` values. All layout decisions happen here. `Action` values arrive from hotkeys and from system events the shell translates; `Effect` values describe side-effects without performing them.

## 3. [WindowManager](03-windowmanager.md)

The impure shell. `WindowManager` owns the live `TilerState` and the AX/CG bridge, dispatches actions through the reducer, runs the coalesced drain loop until frames converge, and reaps windows that have disappeared. This stage covers the dispatch entry point, the convergence model (echo vs genuine move, the bounded corrector), reaping, and screen-lifecycle guards.

## 4. [Reconcile](04-reconcile.md)

The shell's input side. The reconcile loop discovers windows from `CGWindowList` and AX, filters which are tileable, resolves `CGWindowID` ↔ `AXUIElement` identities through a transient private bridge, adopts orphans, and suppresses reaping when observations are unreliable (lock, wake, fullscreen transitions).

## 5. [AX](05-ax.md)

The shell's output side. `AXObserver` subscriptions deliver window events; `AXUIElement` attribute writes move and resize windows. This stage covers blocking subscription calls, subscription-callback lifetime, the pos→size→pos write order, and the `AXEnhancedUserInterface` toggle that works around apps that animate programmatic frame writes.

## Cross-cutting topics

Some concerns span more than one stage. They live in [../topics/](../topics/) and cross-link back into the stages:

- [Native tabs](../topics/native-tabs.md) — `GroupKey` (state), `raiseTabbedWindows` (reducer), tab-swap detection (reconcile).
- [Focus](../topics/focus.md) — AX focus notifications (AX), pre-navigation focus sync (WindowManager), focus clamping (reducer).
- [Config and startup](../topics/config.md) — config reload, deferred Accessibility startup, persistence, crash recovery.