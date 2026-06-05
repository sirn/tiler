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
    /// Records expected frames in the store for echo suppression.
    public static func applyFrames(_ frames: [CGWindowID: NSRect], store: WindowStore) {
        for (wid, frame) in frames {
            guard let element = store.element(for: wid) else { continue }
            var pos = frame.origin
            var size = frame.size

            guard let posValue = AXValueCreate(.cgPoint, &pos),
                  let sizeValue = AXValueCreate(.cgSize, &size) else { continue }

            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)

            store.recordExpectedFrame(frame, for: wid)
        }
    }

    /// Apply a single frame to an AXUIElement directly.
    @discardableResult
    public static func applyFrame(_ frame: NSRect, to element: AXUIElement) -> Bool {
        var pos = frame.origin
        var size = frame.size

        guard let posValue = AXValueCreate(.cgPoint, &pos) else { return false }
        guard let sizeValue = AXValueCreate(.cgSize, &size) else { return false }

        let posResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
        let sizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)

        return posResult == .success && sizeResult == .success
    }
}
