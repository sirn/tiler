# 02 — Reducer

The reducer is the pure core. It turns an action and the current state into a new state plus a list of side-effects, without touching the outside world. This stage covers the `Action` values that go in, the `Reducer.apply` function itself, and the `Effect` values that come out.

## Action

An `Action` enum value describes an intent — e.g. `.focusColumnLeft`, `.focusWorkspace(3)`, `.consumeOrExpelRight`, `.closeWindow`. It describes *what the user or system wants* and carries only its arguments (e.g. the workspace index).

Actions come from two sources:

- Hotkey presses (Carbon), parsed into `Action` values by the keybind parser.
- System events: `AXObserver` and `NSWorkspace` notifications, plus the periodic `CGWindowList` reconcile pass, translated into `Action` values by the shell. Focus-event translation is covered in [../topics/focus.md](../topics/focus.md).

## Reducer.apply

A pure static function handles decisions about which column is focused, where a moved window lands, and how widths change:

```swift
enum Reducer {
  static func apply(
    _ action: Action,
    to state: inout TilerState,
    env: ReducerEnv
  ) -> [Effect]
}
```

The purity contract: the reducer reads only `state` and `env` and emits a new state plus effects. AX, CG, filesystem, timers, and other I/O live in the shell. `ReducerEnv` carries the read-only inputs the reducer needs to make decisions (`workspaceCount`, `activeScreenID`, `orderedScreenIDs`, `focusColumnWrap`) and carries no live handles. The same `(action, state, env)` always yields the same new state and effects.

Rationale: `Tests/TilerCoreTests/` constructs a `TilerState`, applies actions, and asserts on the resulting state and effects with no AX or CG access. Column math, viewport scrolling, and focus-clamping bugs are reproducible without launching the app. The suite has 80 pure-data tests.

## Effect

An `Effect` enum value is a description of a side-effect. The reducer returns a list of these; the shell ([03-windowmanager.md](03-windowmanager.md)) decides how and when to perform them.

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

`.retile` asks the shell to recompute and write frames; `.focusFocusedWindow` asks it to raise a window via AX; `.closeWindow` asks it to press the window's close button; `.log` asks it to emit a log line. An effect carries only the identifiers needed to perform it (a `CGWindowID`, a screen/workspace pair, a string); the `AXUIElement` is resolved from `WindowStore` at execution time (see [04-reconcile.md](04-reconcile.md)). Effects are `Equatable` so tests can assert on them.

`raiseTabbedWindows` is emitted only from within-column focus changes; see [../topics/native-tabs.md](../topics/native-tabs.md).