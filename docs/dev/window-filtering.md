# Window filtering

`WindowFilter.isTileable(_:)` decides whether a discovered window enters the tile set. The check is a pipeline of guards applied in order: role, subrole with a close-button requirement, minimized, fullscreen, and owner activation policy. Each guard exists because a previous version admitted (or rejected) a window it should not have; the commit citations below record those cases.

## Checks, in order

The guards run in this order; the first failure rejects the window.

```swift
public static func isTileable(_ element: AXUIElement) -> Bool {
  // 1. Role: AXWindow, or AXTextField (Emacs — see below)
  // 2. Subrole: reject AXSheet/AXDrawer/AXSystemDialog/AXFloatingWindow/Quick Look;
  //    AXStandardWindow and all other subroles require a close button
  // 3. Not minimized
  // 4. Not fullscreen
  // 5. Owner app activation policy .regular
}
```

### Role: the Emacs exception

The role must be `kAXWindowRole`. `AXTextField` is also accepted: Emacs's NS port reports its main window with role `AXTextField`. This is safe because `kAXWindowsAttribute` returns only window-level elements; a text field inside another app's window never reaches this function.

### Subrole

The subrole narrows which window types are accepted. A reject list excludes sheets and panels outright; every other subrole, including `AXStandardWindow`, must present a close button.

```swift
switch subroleStr {
case "AXSheet", "AXDrawer", "AXSystemDialog", "AXFloatingWindow", "Quick Look":
  return false
case "AXStandardWindow":
  // require a close button
default:
  // AXDialog, AXUnknown, etc. — require a close button
}
```

`AXSheet` is a save/open sheet attached to a window. `AXFloatingWindow` is a floating panel (color picker, Fonts panel). `Quick Look` is the subrole string Finder's space-bar preview uses. These are rejected outright. All other subroles, including `AXStandardWindow`, require a close button:

```swift
guard
  AXUIElementCopyAttributeValue(
    element, kAXCloseButtonAttribute as CFString, &closeButton
  ) == .success, closeButton != nil
else { return false }
```

### AXStandardWindow is not sufficient

macOS Open/Save panels promoted to standalone windows report `AXStandardWindow` but lack a close button; tiling them would let `closeWindow` fail to close them. Chromium extension popups have `AXUnknown` subrole and no window buttons but pass the default case. The durable rule is the close-button check — macOS promotes more windows to `AXStandardWindow` over time, so checking for chrome is more robust than checking the subrole string.

`AXDialog` is tileable only with a close button: chrome-bearing dialogs are legitimate; chrome-less popups such as the Telegram attachment menu are not.

### Minimized and fullscreen

Minimized windows are filtered here; the reconcile loop reaps them and `wasNotTileableLastPass` remembers them so unminimizing restores the column (see [screen-lifecycle.md](screen-lifecycle.md)). Fullscreen windows are also filtered. `WindowFilter.isFullscreen` separately detects native fullscreen (dedicated Space) so the reconciler treats an absent window as on a hidden Space rather than gone.

### Activation policy

The owner process must be a regular app.

```swift
guard let app = NSRunningApplication(processIdentifier: pid),
  app.activationPolicy == .regular
else { return false }
```

`.accessory` and `.prohibited` apps are not tiled.

## Modifying the filter

- Reject anything macOS may promote to `AXStandardWindow` via the close-button check.
- Accepting a new role or subrole requires a real-app justification (as for Emacs) and confirmation that `kAXWindowsAttribute` scoping makes it safe.
- Verify against the safe test apps ([README.md](README.md)): Finder exercises tabs and dialogs; Calculator exercises small rigid windows.