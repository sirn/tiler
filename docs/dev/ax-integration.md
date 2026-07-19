# AX integration

Tiler interacts with macOS Accessibility (AX) through two surfaces: `AXObserver` for event subscription and `AXUIElement` attribute writes for moving and resizing windows. Both have failure modes that require explicit handling — blocking subscription calls, subscription-callback lifetime, and apps that animate programmatic frame writes.

## AXObserver subscription threading

`AXObserverAddNotification` can block for seconds on an unresponsive app. Running it on the main thread froze Tiler's UI on one hung process (Phoenix #114). Subscription runs on a concurrent utility queue; the run-loop source is attached on the main thread so `deinit` removes it deterministically. Events arriving before subscription completes are recovered by the periodic `CGWindowList` reconcile loop — that backstop is why the reconcile loop exists independently of the event stream.

## Refcon lifetime

`AXObserverAddNotification` stores a refcon returned to the callback. The subscription block strong-captures `self` so the observer outlives the subscription — capturing `self` unretained with only a weak check at block entry would dangle the refcon if `self` deinited mid-subscription. Preserve the strong-capture when modifying `AppObserver`.

## AXEnhancedUserInterface

Apps that set `AXEnhancedUserInterface` (EUI) — Ghostty, Helium — coalesce and animate programmatic `AXPosition` / `AXSize` writes. A write lands on an intermediate animated frame, so the corrector's pos→size→pos sequence never converges; the corrector re-issued frames indefinitely while each snap-back retile reset its 3-attempt budget.

The workaround toggles EUI off around each frame write and restores it after — the same approach as Rectangle, Amethyst, and Glide:

```swift
private static func withEUIDisabled<T>(pid: pid_t, _ body: () -> T) -> T {
  let app = AXUIElementCreateApplication(pid)
  var euiRef: CFTypeRef?
  let readStatus = AXUIElementCopyAttributeValue(
    app, "AXEnhancedUserInterface" as CFString, &euiRef)

  if readStatus == .attributeUnsupported
    || readStatus == .notImplemented
    || euiRef as? Bool != true
  { return body() }  // no EUI or already off — no-op

  if AXUIElementSetAttributeValue(
    app, "AXEnhancedUserInterface" as CFString, false as CFTypeRef) != .success
  { return body() }  // couldn't disable — leave untouched, skip restore

  defer { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, true as CFTypeRef) }
  return body()
}
```

Properties:

- No-op when the attribute is unsupported, unimplemented, or already false.
- Skip-restore on disable failure — avoids flipping an app that was never disabled.
- No lock needed — all frame writes run on the main-thread-serialized drain loop.

### Batching

`applyFrames` groups elements by PID and wraps each app's batch in one `withEUIDisabled`:

```swift
var buckets: [pid_t: [(element: AXUIElement, frame: NSRect)]] = [:]
for (wid, frame) in frames { /* bucket by PID */ }
for (pid, entries) in buckets {
  withEUIDisabled(pid: pid) {
    for entry in entries { applyOne(entry.element, entry.frame, screenHeight: screenHeight) }
  }
}
```

Each app toggles at most once per drain. The single-batch write lets the corrector's three-attempt budget (see [architecture.md](architecture.md)) converge in bounded time on EUI apps.

## pos→size→pos

macOS clamps a window's position based on its current size; setting position then resizing can leave the window off-screen. `applyOne` writes position, then size, then position again. EUI animation disrupts this because the intermediate states the corrector reads back are animated transitions, not settled frames, so `framesMatch` never succeeds and the budget never resets.