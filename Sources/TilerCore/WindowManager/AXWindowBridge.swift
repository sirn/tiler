import AppKit
import ApplicationServices
import CoreGraphics

public enum AXWindowBridgeError: Error {
    case cannotGetWindowID
    case cannotSetPosition
    case cannotSetSize
}

public enum AXWindowBridge {
    
    /// Enumerate all on-screen windows via CGWindowList, returning tileable ones.
    public static func enumerateWindows() -> [(windowID: CGWindowID, element: AXUIElement, pid: pid_t, title: String)] {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        
        var results: [(CGWindowID, AXUIElement, pid_t, String)] = []
        
        for info in windowInfo {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let windowNumber = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            
            // Skip windows with layer > 0 (menus, cursors, etc.)
            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }
            
            let appElement = AXUIElementCreateApplication(pid)
            var appWindows: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &appWindows)

            guard result == .success, let windows = appWindows as? [AXUIElement] else { continue }

            for window in windows {
                // Use CGWindowID from the owner's PID since AXUIElementGetWindowID is not available
                // Match by window position on the owner's window list index
                let title = info[kCGWindowName as String] as? String ?? ""
                results.append((windowNumber, window, pid, title))
            }
        }
        
        return results
    }
    
    /// Apply frames to multiple windows at once.
    public static func applyFrames(_ frames: [CGWindowID: NSRect]) {
        for (windowID, frame) in frames {
            // Find the AXUIElement for this window ID
            guard let match = findWindowByID(windowID) else { continue }
            applyFrame(frame, to: match)
        }
    }
    
    /// Apply a single frame to an AXUIElement.
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
    
    /// Find a window AXUIElement by its CGWindowID (from PID enumeration).
    public static func findWindowByID(_ windowID: CGWindowID) -> AXUIElement? {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in windowInfo {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let number = info[kCGWindowNumber as String] as? CGWindowID, number == windowID else { continue }

            // Get position/size from CGWindowList for matching
            let cgRectDict = info[kCGWindowBounds as String] as? [String: Any]
            let cgX = cgRectDict?["X"] as? CGFloat
            let cgY = cgRectDict?["Y"] as? CGFloat
            let cgW = cgRectDict?["Width"] as? CGFloat
            let cgH = cgRectDict?["Height"] as? CGFloat

            let appElement = AXUIElementCreateApplication(pid)
            var appWindows: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &appWindows)

            guard result == .success, let windows = appWindows as? [AXUIElement] else { continue }

            // If only one window for this PID, return it directly
            if windows.count == 1, let only = windows.first {
                return only
            }

            // Match by position/size to find the correct AX window
            if cgX != nil || cgY != nil || cgW != nil || cgH != nil {
                for window in windows {
                    var posValue: CFTypeRef?
                    var sizeValue: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
                       AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
                       CFGetTypeID(posValue) == AXValueGetTypeID(),
                       CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                        let posAX = unsafeBitCast(posValue, to: AXValue.self)
                        let sizeAX = unsafeBitCast(sizeValue, to: AXValue.self)
                        var pos = CGPoint.zero
                        var size = CGSize.zero
                        if AXValueGetValue(posAX, .cgPoint, &pos),
                           AXValueGetValue(sizeAX, .cgSize, &size) {
                            if (cgX == nil || abs(pos.x - cgX!) < 5) &&
                               (cgY == nil || abs(pos.y - cgY!) < 5) &&
                               (cgW == nil || abs(size.width - cgW!) < 5) &&
                               (cgH == nil || abs(size.height - cgH!) < 5) {
                                return window
                            }
                        }
                    }
                }
            }

            // Fallback: return first window if no position match
            return windows.first
        }
        return nil
    }
}
