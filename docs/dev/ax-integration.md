# AX integration: subscription threading and the EUI frame-write workaround

This page covers the two AX integration points that have historically caused the most subtle bugs: how `AXObserver` subscriptions are threaded, and how `AXEnhancedUserInterface` interferes with programmatic frame writes.

## Subscribing off the main thread (commit `4e0c364`)

`AXObserverAddNotification` can block for seconds on an unresponsive app. Originally it ran on the main thread, so one hung process froze Tiler's entire UI:

> AXObserverAddNotification can block for seconds on an unresponsive app (Phoenix #114). Move notification subscription to a concurrent utility queue so a hung process cannot freeze the main run loop.

The subscription now runs on a concurrent utility queue. The run-loop source is still attached on the main thread so `deinit` removes it deterministically. Events that arrive before subscription completes are not lost — the periodic `CGWindowList` reconcile loop recovers them. That recovery path is why the reconcile loop exists independently of the event stream: it's the backstop for any event we miss.

## Refcon lifetime (commit `1d7d0cf`)

`AXObserverAddNotification` stores a refcon (context pointer) that comes back to us in the callback. `AppObserver` used to capture `self` as an unretained refcon while only weakly checking `self` at entry to the subscription block:

> If `self` deinited mid-subscription, `AXObserverAddNotification` stored a dangling refcon and a later event would dereference it. Strong-capture `self` in the subscription block so it outlives subscription.

The fix strong-captures `self` in the subscription block so the observer outlives the subscription. This is the kind of lifetime bug that only manifests under teardown timing, which is exactly when it's hardest to reproduce — if you change `AppObserver`, preserve the strong-capture.

## `AXEnhancedUserInterface` and frame writes (commit `32489b8`)

This is the most important AX workaround in the codebase. Some apps (Ghostty, Helium) set `AXEnhancedUserInterface` (EUI), which causes them to **coalesce and animate** programmatic `AXPosition`/`AXSize` writes. A frame write then lands on an intermediate animated frame, so the corrector's pos→size→pos sequence never converges:

> The corrector re-issued frames indefinitely while every snap-back retile reset its 3-attempt budget, leaving windows drifting on their own after a move.

The workaround toggles EUI off around each frame write and restores it immediately after — the same trick used by Rectangle, Amethyst, and Glide:

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
  { return body() }  // couldn't disable — leave it untouched, skip restore

  defer { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, true as CFTypeRef) }
  return body()
}
```

Three properties make this safe:

- **No-op when not needed.** If the attribute is unsupported, unimplemented, or already false, `body()` runs untouched. The toggle only fires for apps that actually have EUI on.
- **Skip-restore on disable failure.** If we couldn't turn EUI off, we don't try to turn it back on — that would flip an app we never managed to disable. We just run `body()`.
- **Main-thread serialized.** All frame writes run on the main thread (the drain loop is main-thread serialized), so the read-modify-restore of an app's EUI flag needs no lock.

### Batching: one toggle per app per drain

EUI toggling is expensive, so the corrector batches re-issues into a single `applyFrames` call per drain. `applyFrames` groups resolved elements by PID and wraps each app's batch in one `withEUIDisabled`:

```swift
var buckets: [pid_t: [(element: AXUIElement, frame: NSRect)]] = [:]
for (wid, frame) in frames { /* bucket by PID */ }
for (pid, entries) in buckets {
  withEUIDisabled(pid: pid) {
    for entry in entries { applyOne(entry.element, entry.frame, screenHeight: screenHeight) }
  }
}
```

Without batching, the corrector would toggle EUI once per window per drain; with it, each app toggles at most once per drain cycle. The single-batch write also means the corrector's three-attempt budget (see [architecture.md](architecture.md)) converges in bounded time on EUI apps.

## The pos→size→pos sequence

Why frame writes are a sequence, not one call. macOS clamps a window's position based on its current size, so setting position first and then resizing can leave the window off-screen:

```swift
// pos→size→pos write for a single element. macOS clamps a window's position based on
// its current size, so position is reapplied after the resize to correct any clamping.
```

`applyOne` writes position, then size, then position again. This is why EUI animation is so disruptive — the intermediate states the corrector reads back are from an animated transition, not a settled frame, so `framesMatch` never succeeds and the budget never resets.