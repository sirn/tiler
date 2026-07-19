# Window filtering: what counts as tileable

`WindowFilter.isTileable(_:)` is the single gate that decides whether a discovered window enters the tile set. It looks short, but every clause exists because a previous version let something through (or rejected something it shouldn't have). Read this before changing the gate.

## The check, in order

```swift
public static func isTileable(_ element: AXUIElement) -> Bool {
  // 1. Role: AXWindow, or AXTextField (Emacs — see below)
  // 2. Subrole: reject AXSheet/AXDrawer/AXSystemDialog/AXFloatingWindow/Quick Look;
  //    AXStandardWindow and everything else require a close button
  // 3. Not minimized
  // 4. Not fullscreen
  // 5. Owner app is .regular activation policy
}
```

### Role — and the Emacs exception

The role must be `kAXWindowRole`. The one exception is `AXTextField`, which exists because of commit `cb82d18`:

> Emacs's NS port reports its main window with role `AXTextField` instead of `AXWindow`, causing `WindowFilter.isTileable` to reject it at the role check before the subrole/close-button guards ran.

This is safe because `kAXWindowsAttribute` only returns window-level elements — a stray text field inside another app's window never reaches this function. The downstream subrole and close-button guards still bound what an `AXTextField` element must look like to pass.

### Subrole — the reject list and the close-button requirement

The subrole switch is the heart of the filter:

```swift
switch subroleStr {
case "AXSheet", "AXDrawer", "AXSystemDialog", "AXFloatingWindow", "Quick Look":
  return false
case "AXStandardWindow":
  // ... require a close button ...
default:
  // AXDialog, AXUnknown, etc. — require a close button
}
```

`AXSheet` is a save/open sheet attached to a window. `AXFloatingWindow` is a floating panel (color picker, Fonts panel). `Quick Look` is the literal subrole string Finder's space-bar preview uses (commit `a117974`). These are rejected outright.

Everything else — including `AXStandardWindow` — must present a close button:

```swift
guard
  AXUIElementCopyAttributeValue(
    element, kAXCloseButtonAttribute as CFString, &closeButton
  ) == .success, closeButton != nil
else { return false }
```

### Why `AXStandardWindow` is not enough

This is the most-revisited clause. Commit `e4291b3`:

> macOS file dialogs (Open/Save panels promoted to standalone windows in newer OS versions) report `AXStandardWindow` subrole but lack a close button. Previously, `AXStandardWindow` was trusted unconditionally as tileable, causing file dialogs to be tracked as tiles — the dialog would be tiled alongside regular windows and `closeWindow` couldn't close it (no close button to press).

And commit `e3192ac` generalized the close-button guard to the default branch:

> Chromium extension popups (e.g. Helium) have `AXUnknown` subrole and no window buttons, but were passing the tileability filter because `AXUnknown` fell through to the default case which allowed all non-standard subroles through.

The rule that falls out: **`AXStandardWindow` is not a certificate of tileability; a close button is.** macOS promotes more things to `AXStandardWindow` over time, so checking for chrome (a close button) is more robust than checking the subrole string. If you relax this, you will start tiling file dialogs.

`AXDialog` is tileable *if* it has a close button — chrome-bearing dialogs like some preferences windows are legitimate; chrome-less popups like the Telegram attachment menu are not (commit `a117974`).

### Minimized and fullscreen

Minimized windows are filtered out here; the reconcile loop reaps them and the `wasNotTileableLastPass` set remembers them so unminimizing restores their column (see [screen-lifecycle.md](screen-lifecycle.md)). Fullscreen windows are also filtered — `WindowFilter.isFullscreen` separately detects native-fullscreen (dedicated Space) so the reconciler knows an absent window is on a hidden Space, not gone.

### Activation policy

```swift
guard let app = NSRunningApplication(processIdentifier: pid),
  app.activationPolicy == .regular
else { return false }
```

`.accessory` (menu-bar helpers, some daemons) and `.prohibited` apps are not tiled. This rejects background processes that happen to own a window.

## Changing the filter

Three rules:

1. **Add a reject clause for anything macOS might promote to `AXStandardWindow` later.** The close-button check is the durable version of this.
2. **If you accept a new role or subrole, justify it with a real app** (as `cb82d18` does for Emacs), and confirm `kAXWindowsAttribute` scoping makes it safe.
3. **Test against the safe test apps** in [README.md](README.md) — Finder exercises tabs and dialogs, Calculator exercises small rigid windows. A filter change that breaks either is usually visible immediately.