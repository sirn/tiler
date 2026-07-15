import AppKit
import ApplicationServices
import CoreGraphics

public enum AXWindowBridge {
  /// Primary screen height is the correct anchor for the global Cocoa coordinate system.
  /// macOS uses the primary screen as the global coordinate anchor, so the Cocoa↔AX
  /// Y-flip formula works universally for all screens.
  internal static func primaryScreenHeight() -> CGFloat {
    NSScreen.screens.first?.frame.height ?? CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
  }

  /// Apply frames to multiple windows at once, using a WindowStore for element lookup.
  /// Issues each frame once (pos→size→pos); convergence is managed by the caller's corrector.
  ///
  /// Windows are bucketed by owning PID so the per-app `AXEnhancedUserInterface` toggle
  /// is applied once per process rather than once per window.
  public static func applyFrames(_ frames: [CGWindowID: NSRect], store: WindowStore) {
    // The Cocoa↔AX y-flip uses the primary screen height as the global coordinate anchor.
    let screenHeight = primaryScreenHeight()

    // Group resolved elements by PID so EUI is toggled once per app.
    var buckets: [pid_t: [(element: AXUIElement, frame: NSRect)]] = [:]
    for (wid, frame) in frames {
      guard let element = store.element(for: wid) else { continue }
      var pid: pid_t = 0
      guard AXUIElementGetPid(element, &pid) == .success else { continue }
      buckets[pid, default: []].append((element, frame))
    }

    for (pid, entries) in buckets {
      withEUIDisabled(pid: pid) {
        for entry in entries {
          applyOne(entry.element, entry.frame, screenHeight: screenHeight)
        }
      }
    }
  }

  /// Apply a single frame to an AXUIElement directly.
  @discardableResult
  public static func applyFrame(_ frame: NSRect, to element: AXUIElement) -> Bool {
    let screenHeight = primaryScreenHeight()
    var pid: pid_t = 0
    _ = AXUIElementGetPid(element, &pid)

    return withEUIDisabled(pid: pid) {
      var pos = CGPoint(x: frame.minX, y: screenHeight - frame.maxY)
      var size = frame.size

      guard let posValue = AXValueCreate(.cgPoint, &pos) else { return false }
      guard let sizeValue = AXValueCreate(.cgSize, &size) else { return false }

      let posResult = AXUIElementSetAttributeValue(
        element, kAXPositionAttribute as CFString, posValue)
      let sizeResult = AXUIElementSetAttributeValue(
        element, kAXSizeAttribute as CFString, sizeValue)

      return posResult == .success && sizeResult == .success
    }
  }

  // MARK: - EUI toggle

  /// Temporarily disable `AXEnhancedUserInterface` for an app around a frame write.
  ///
  /// Apps that opt into EUI (e.g. Ghostty, Helium) coalesce and animate geometry changes,
  /// which prevents the pos→size→pos sequence from converging. Toggling it off makes each
  /// write land instantly. On apps without EUI or where it is already off, this is a no-op.
  ///
  /// All AX frame writes run on the main thread (the reconcile/drain loop is main-thread
  /// serialized), so no lock is needed to guard the read-modify-restore of an app's EUI flag.
  private static func withEUIDisabled<T>(pid: pid_t, _ body: () -> T) -> T {
    let app = AXUIElementCreateApplication(pid)
    var euiRef: CFTypeRef?
    let readStatus = AXUIElementCopyAttributeValue(
      app, "AXEnhancedUserInterface" as CFString, &euiRef)

    if readStatus == .attributeUnsupported
      || readStatus == .notImplemented
      || euiRef as? Bool != true
    {
      return body()
    }

    if AXUIElementSetAttributeValue(
      app, "AXEnhancedUserInterface" as CFString, false as CFTypeRef) != .success
    {
      // Couldn't disable; leave EUI untouched and skip the restore to avoid flipping
      // an app we never managed to turn off.
      return body()
    }

    tiler_debug("AX EUI: disabling for pid \(pid)")
    defer {
      if AXUIElementSetAttributeValue(
        app, "AXEnhancedUserInterface" as CFString, true as CFTypeRef) != .success
      {
        tiler_debug("AX EUI: restore failed for pid \(pid)")
      } else {
        tiler_debug("AX EUI: restored for pid \(pid)")
      }
    }
    return body()
  }

  // MARK: - Helpers

  /// pos→size→pos write for a single element. macOS clamps a window's position based on
  /// its current size, so position is reapplied after the resize to correct any clamping.
  /// `screenHeight` is passed in rather than re-read per call so a batch shares one anchor.
  private static func applyOne(_ element: AXUIElement, _ frame: NSRect, screenHeight: CGFloat) {
    var pos = CGPoint(x: frame.minX, y: screenHeight - frame.maxY)
    var size = frame.size
    if let v = AXValueCreate(.cgPoint, &pos) {
      AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v)
    }
    if let v = AXValueCreate(.cgSize, &size) {
      AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v)
    }
    // Second position pass corrects placement after resize
    if let v = AXValueCreate(.cgPoint, &pos) {
      AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v)
    }
  }

  /// Read back a window's actual frame from AX attributes (reflects what the app accepted).
  /// Converts AX top-left origin back to Cocoa bottom-left NSRect.
  static func getAXFrame(_ element: AXUIElement, screenHeight: CGFloat) -> NSRect? {
    var axPosRef: CFTypeRef?
    var axSizeRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &axPosRef)
        == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &axSizeRef) == .success,
      let axPosRef, let axSizeRef,
      CFGetTypeID(axPosRef) == AXValueGetTypeID(),
      CFGetTypeID(axSizeRef) == AXValueGetTypeID()
    else { return nil }
    let posAX = unsafeBitCast(axPosRef, to: AXValue.self)
    let sizeAX = unsafeBitCast(axSizeRef, to: AXValue.self)
    var axPos = CGPoint.zero
    var axSize = CGSize.zero
    guard AXValueGetValue(posAX, .cgPoint, &axPos),
      AXValueGetValue(sizeAX, .cgSize, &axSize)
    else { return nil }
    // Inverse of the apply conversion: AX y is top-left, Cocoa y is bottom-left
    let cocoaY = screenHeight - axPos.y - axSize.height
    return NSRect(x: axPos.x, y: cocoaY, width: axSize.width, height: axSize.height)
  }

  /// Check if two frames match within tolerance.
  static func framesMatch(_ a: NSRect, _ b: NSRect, tolerance: CGFloat) -> Bool {
    return TilerCore.framesMatch(a, b, tolerance: tolerance)
  }

  /// Read the current AX frame for an element using the primary screen height.
  static func currentFrame(for element: AXUIElement) -> NSRect? {
    return getAXFrame(element, screenHeight: primaryScreenHeight())
  }
}
