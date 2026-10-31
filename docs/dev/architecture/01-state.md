# 01 — State

`TilerState` is a tree of plain Swift value types describing every managed window and its placement. It is the single source of truth for layout — the shell uses it as its sole model of where windows are.

```
TilerState
└─ screens: [ScreenID: ScreenState]
   └─ activeWorkspaceID, info (frame, visibleFrame)
   └─ workspaces: [WorkspaceID: Workspace]
      └─ focusedColumnIndex, scrollOffset
      └─ columns: [Column]
         └─ mode (.stack | .tab), width (.proportion | .fixed), focusedWindowIndex,
            measuredMinWidth?, measuredMinHeight?
         └─ windows: [WindowNode]
            └─ id: CGWindowID, groupKey: GroupKey, pid, title
```

Everything is a value type, so a mutation is a copy-and-replace. State holds only value-type data — `AXUIElement`, file descriptors, and timers all live in the shell. This is what lets the reducer ([02-reducer.md](02-reducer.md)) mutate state without performing I/O.

## GroupKey

Since `CGWindowID` is transient due to native tabs, a stable process-local identity `GroupKey` is generated for each tile, surviving native-tab backing-ID swaps:

```swift
private var nextGroupToken: UInt64 = 0
private func mintGroupKey() -> WindowNode.GroupKey {
  nextGroupToken &+= 1
  return WindowNode.GroupKey(value: nextGroupToken)
}
```

The window node stores `groupKey` alongside `id` (the current `CGWindowID`). `appliedWindows` and the corrector (see [03-windowmanager.md](03-windowmanager.md)) are keyed by `GroupKey`, so a tab swap changes `id` but not `groupKey`, preserving the frame record and convergence state. The tab-swap mechanics that drive these swaps are covered in [../topics/native-tabs.md](../topics/native-tabs.md).

## measuredMinWidth / measuredMinHeight

A column records the real minimum size of a window that resisted sizing, so subsequent layouts honor it. The values are absorbed by the corrector (see [03-windowmanager.md](03-windowmanager.md#bounded-corrector)) and reset when a window returns from fullscreen or minimize (see [03-windowmanager.md](03-windowmanager.md#wasnottileablelastpass-reset)).