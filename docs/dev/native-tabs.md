# Native macOS tabs: one tile per tab group

macOS native tabs (Finder Cmd+T, Safari, Ghostty, Terminal, Chromium) are multiple `CGWindowID`s that share a single on-screen frame — only the active tab is visible. If Tiler tiled each tab ID as its own column, every background tab would render as an invisible column occupying layout space. Tiler instead collapses a tab group to a single tile and swaps which `CGWindowID` backs it as the user switches tabs.

## Stable identity via `GroupKey`

A tile's identity is **not** its `CGWindowID` — tab IDs come and go. Each tile gets a minted `GroupKey`:

```swift
private var nextGroupToken: UInt64 = 0
private func mintGroupKey() -> WindowNode.GroupKey {
  nextGroupToken &+= 1
  return WindowNode.GroupKey(value: nextGroupToken)
}
```

The window node stores `groupKey` alongside `id` (the current `CGWindowID`). `appliedWindows` and the corrector are keyed by `GroupKey`, so a tab swap (which changes `id` but not `groupKey`) doesn't lose the frame record or reset convergence. Commit `65c7150` introduced this: "Give each tile a stable GroupKey identity so it survives tab-id swaps."

## Detecting a tab swap: `resolveActiveTabSwap`

When the visible window at a tile's frame changes, that's a tab swap. The resolver finds the active tab by scanning `CGWindowList` for on-screen windows of the same PID at the tile's frame:

```swift
private func windowIDsAtFrame(pid: pid_t, cocoaFrame: NSRect, tolerance: CGFloat) -> [CGWindowID]
{
  // CGWindowListCopyWindowInfo, filter by owner==pid, layer<=0,
  // convert CG (top-left Y) to Cocoa (bottom-left Y) and frame-match.
}
```

Note the coordinate flip: `CGWindowList` bounds are top-left origin; AX and our layout use Cocoa bottom-left origin. The conversion uses the primary screen height as the global anchor (same anchor `AXWindowBridge` uses for frame writes).

### The `kAXMain` tiebreaker

Some apps (Safari, Chrome) keep **all** tabs in the on-screen `CGWindowList`, so `windowIDsAtFrame` returns several matches at the same frame. `resolveActiveTabSwap` breaks the tie with the AX `kAXMainAttribute`:

```swift
var mainCandidates: [CGWindowID] = []
for match in matches {
  let element = windowStore.element(for: match) ?? windowStore.liveElement(forPID: pid, wid: match)
  // ... if kAXMainAttribute == true, append ...
}
if mainCandidates.count == 1 { activeWid = mainCandidates[0] }
else { return nil }  // 0 or >1 with main == true — ambiguous, refuse to swap
```

Refusing on ambiguity is deliberate — a wrong swap would bind the tile to the wrong tab's element. The reconciler will retry. Commit `03a7526` unified three previously-separate swap paths (reconcile correlation, focus-time adoption, `refreshActiveTabs`) into this one primitive so they all apply the same tiebreaker and the same title-freshness rule.

### Title freshness

Before `03a7526`, swap paths sometimes kept the stale node title. The unified path re-reads `kCGWindowName` (with a `kAXTitleAttribute` fallback) for the active tab on every swap, so the tile's title always reflects the active tab.

## Raising tabs: `raiseTabbedWindows`, scoped to the column

In `.tab` mode only one tab is visible; raising the focused tab means re-ordering the others behind it. The `raiseTabbedWindows` effect re-orders non-active tabs back-to-front, then `focusFocusedWindow` raises the focused window on top.

Crucially, the reducer only emits `raiseTabbedWindows` from `focusWindowUp`/`focusWindowDown` (focus changes *within* a column). Commit `b9b7740`:

> Other focus paths (`focusColumnLeft`/`Right`, `focusWorkspace`, `focusScreen*`) skip it so crossing a column boundary into a tabbed column does not re-order the whole stack.

Without that scoping, moving focus *into* a tabbed column would shuffle that column's tab stack — surprising and wrong.

## Merging new tabs into the focused column

When a new window appears with the same PID as an existing tab group (the user pressed Cmd+T), `addWindowToActiveWorkspace` merges it into the focused column **first**, falling back to a new column only if no same-PID column is focused. Commit `03a7526` scoped this merge to the focused column to reduce the risk of merging into the wrong same-PID column when several exist.

## Where this goes wrong

Tab bugs almost always look like one of:

- **A new column appears on Cmd+T** — the merge didn't fire, usually because the new window's PID didn't match the focused column's, or the focused-column check was too strict.
- **A background tab becomes an invisible column** — the swap wasn't detected; check `resolveActiveTabSwap`'s ambiguity refusal and whether `kAXMain` is set on the active tab in that app.
- **The wrong tab is raised after focus** — `raiseTabbedWindows` fired from a path it shouldn't have (re-check the reducer cases that emit it).

The tab system is the single best argument for the "refuse rather than guess" posture in [window-identity.md](window-identity.md): a guessed tab binding is worse than a deferred one.