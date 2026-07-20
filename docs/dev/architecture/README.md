# Architecture

Tiler's runtime splits cleanly into a **pure core** that decides what the layout should be and an **impure shell** that makes it so by talking to macOS. The reducer is the only thing that mutates `TilerState`; the shell reads the outside world before the reducer and acts on its results after. This split keeps layout logic testable without AX or CG access — `Tests/TilerCoreTests/` runs with no Accessibility or screen access.

## Pure core and shell

- **Pure core** (no AX/CG): [State (01)](01-state.md), [Reducer (02)](02-reducer.md).
- **Shell** (impure; AX/CG): `WindowManager` ([03](03-windowmanager.md)) consists of:
  - the **input side** ([Reconcile, 04](04-reconcile.md)) — observes `CGWindowList` + AX, builds `Action`s
  - a **reducer dispatch** — feeds those Actions through `Reducer.apply`, the sole mutator of `TilerState`
  - the **output side** ([AX, 05](05-ax.md)) — runs the emitted `[Effect]` as frame/focus/close writes; subscription events flow back to the input side

## Runtime loop

One pass of the loop, in time:

1. **Observe** — the shell's input side: Reconcile reads `CGWindowList`/AX attributes, and `AXObserver` subscriptions deliver events. Both translate observations into Actions.
2. **Action** — the shell builds the `Action` value to dispatch.
3. **Reducer** — the pure core: `Reducer.apply` mutates `TilerState` and emits `[Effect]`. This is the sole step that touches State.
4. **Run effects** — the shell's output side: `WindowManager` drains `[Effect]`; `AX` writes frames, focuses windows, presses close buttons.
5. **AX/CG writes** — frames land on the real windows, which the next Observe pass sees again, closing the loop back to step 1.

Both sides reach `State` through the reducer; the shell holds no parallel model of layout (see [01-state.md](01-state.md)).

Two actions bypass the reducer because they touch shell-owned state outside `TilerState` (`.toggleFloat`, `.dumpFrameState`); see [03-windowmanager.md](03-windowmanager.md#dispatch-entry-point).

## Stage numbering

The five stage files are numbered **01–05 in read order**, following one data-flow pass from the source of truth outward. Treat the **pure core and shell** grouping and the **runtime loop** above as the mental model; the numbering exists only so cross-references stay stable.

Vocabulary used across these docs is defined in [../README.md](../README.md#concepts-and-vocabulary).

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