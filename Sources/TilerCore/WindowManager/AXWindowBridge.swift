import AppKit
import ApplicationServices
import CoreGraphics

public enum AXWindowBridgeError: Error {
  case cannotGetWindowID
  case cannotSetPosition
  case cannotSetSize
}

public enum AXWindowBridge {

  /// Apply frames to multiple windows at once, using a WindowStore for element lookup.
  /// Issues each frame once (pos→size→pos); convergence is managed by the caller's corrector.
  public static func applyFrames(_ frames: [CGWindowID: NSRect], store: WindowStore) {
    // The Cocoa↔AX y-flip uses the primary screen height only; this is single-display-correct
    // but will produce wrong coordinates on secondary screens. TODO: multi-display support.
    let screenHeight =
      NSScreen.screens.first?.frame.height ?? CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))

    // Apply pos→size→pos: macOS clamps a window's position based on its current size,
    // so position is reapplied after the resize to correct any clamping that occurred.
    func applyOne(_ element: AXUIElement, _ frame: NSRect) {
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

    for (wid, frame) in frames {
      guard let element = store.element(for: wid) else { continue }
      applyOne(element, frame)
    }
  }

  /// Apply a single frame to an AXUIElement directly.
  @discardableResult
  public static func applyFrame(_ frame: NSRect, to element: AXUIElement) -> Bool {
    let screenHeight =
      NSScreen.screens.first?.frame.height ?? CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
    var pos = CGPoint(x: frame.minX, y: screenHeight - frame.maxY)
    var size = frame.size

    guard let posValue = AXValueCreate(.cgPoint, &pos) else { return false }
    guard let sizeValue = AXValueCreate(.cgSize, &size) else { return false }

    let posResult = AXUIElementSetAttributeValue(
      element, kAXPositionAttribute as CFString, posValue)
    let sizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)

    return posResult == .success && sizeResult == .success
  }

  // MARK: - Helpers

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
    // Same primary-screen y-flip limitation as applyFrames. TODO: multi-display support.
    let screenHeight =
      NSScreen.screens.first?.frame.height ?? CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
    return getAXFrame(element, screenHeight: screenHeight)
  }
}
