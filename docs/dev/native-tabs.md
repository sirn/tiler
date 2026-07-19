# Native tabs

macOS native tabs (Finder Cmd+T, Safari, Ghostty, Terminal, Chromium) are multiple `CGWindowID`s sharing a single on-screen frame; only the active tab is visible. Tiler collapses a tab group to one tile and swaps which `CGWindowID` backs it as the user switches tabs. Tiling each tab ID separately would render every background tab as an invisible column occupying layout space.

## GroupKey identity

A tile's identity is not its `CGWindowID` — tab IDs come and go. Each tile is minted a `GroupKey`:

```swift
private var nextGroupToken: UInt64 = 0
private func mintGroupKey() -> WindowNode.GroupKey {
  nextGroupToken &+= 1
  return WindowNode.GroupKey(value: nextGroupToken)
}
```

The window node stores `groupKey` alongside `id` (the current `CGWindowID`). `appliedWindows` and the corrector are keyed by `GroupKey`, so a tab swap changes `id` but not `groupKey`, preserving the frame record and convergence state.

## Tab swap detection: resolveActiveTabSwap

When the visible window at a tile's frame changes, `resolveActiveTabSwap` scans `CGWindowList` for on-screen windows of the same PID at the tile's frame:

```swift
private func windowIDsAtFrame(pid: pid_t, cocoaFrame: NSRect, tolerance: CGFloat) -> [CGWindowID]
{
  // CGWindowListCopyWindowInfo, filter owner==pid, layer<=0,
  // convert CG top-left Y to Cocoa bottom-left Y, frame-match.
}
```

Coordinate flip: `CGWindowList` bounds are top-left origin; AX and layout use Cocoa bottom-left origin. Conversion uses the primary screen height as the global anchor (same anchor `AXWindowBridge` uses for frame writes).

### kAXMain tiebreaker

Some apps (Safari, Chrome) keep all tabs in the on-screen `CGWindowList`, so `windowIDsAtFrame` returns several matches at one frame. `resolveActiveTabSwap` breaks the tie with `kAXMainAttribute`:

```swift
var mainCandidates: [CGWindowID] = []
for match in matches {
  let element = windowStore.element(for: match) ?? windowStore.liveElement(forPID: pid, wid: match)
  // if kAXMainAttribute == true, append
}
if mainCandidates.count == 1 { activeWid = mainCandidates[0] }
else { return nil }  // 0 or >1 with main == true — ambiguous, refuse to swap
```

It returns nil on ambiguity (zero or more than one `main == true` candidate); the reconciler retries. This primitive unifies reconcile correlation, focus-time adoption, and `refreshActiveTabs` into one swap path.

### Title freshness

The unified path re-reads `kCGWindowName` (with `kAXTitleAttribute` fallback) for the active tab on every swap, so the node title stays current.

## raiseTabbedWindows

In `.tab` mode one tab is visible; raising the focused tab re-orders the others behind it. `raiseTabbedWindows` re-orders non-active tabs back-to-front; `focusFocusedWindow` then raises the focused window on top.

The reducer emits `raiseTabbedWindows` only from `focusWindowUp` / `focusWindowDown` (focus changes within a column). Other focus paths (`focusColumnLeft` / `Right`, `focusWorkspace`, `focusScreen*`) skip it, so crossing a column boundary into a tabbed column does not re-order the stack.

## Tab merge on creation

When a new window appears with the same PID as an existing tab group (Cmd+T), `addWindowToActiveWorkspace` merges it into the focused column first, falling back to a new column only if no same-PID column is focused. This is scoped to the focused column to avoid merging into the wrong same-PID column.

## Failure modes

- **A new column appears on Cmd+T** — the merge did not fire; usually a PID mismatch with the focused column or an overly strict focused-column check.
- **A background tab becomes an invisible column** — the swap was not detected; check `resolveActiveTabSwap` ambiguity refusal and whether the app sets `kAXMain` on the active tab.
- **The wrong tab is raised after focus** — `raiseTabbedWindows` fired from a path it should not have; re-check the emitting reducer cases.