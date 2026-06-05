import AppKit
import ApplicationServices
import CoreGraphics

/// Owns the CGWindowID ↔ AXUIElement identity map, refreshed from CGWindowList.
/// Uses the private `_AXUIElementGetWindow` API for exact identity (no position-matching).
public final class WindowStore {
    private var elements: [CGWindowID: AXUIElement] = [:]
    private var pidWindows: [pid_t: Set<CGWindowID>] = [:]
    private var expectedFrames: [CGWindowID: NSRect] = [:]

    /// Rebuild the identity map from CGWindowList + _AXUIElementGetWindow.
    public func refresh() {
        elements.removeAll(keepingCapacity: true)
        pidWindows.removeAll(keepingCapacity: true)

        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        for info in windowInfo {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer <= 0 else { continue }

            let appElement = AXUIElementCreateApplication(pid)
            var appWindows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &appWindows) == .success,
                  let windows = appWindows as? [AXUIElement] else { continue }

            for window in windows {
                var foundWid: CGWindowID = 0
                let err = _AXUIElementGetWindow(window, &foundWid)
                if err == .success, foundWid == wid {
                    elements[wid] = window
                    pidWindows[pid, default: []].insert(wid)
                    break
                }
            }
        }
    }

    /// Get the AXUIElement for a CGWindowID.
    public func element(for id: CGWindowID) -> AXUIElement? {
        return elements[id]
    }

    /// Get the CGWindowID for an AXUIElement via _AXUIElementGetWindow.
    public func windowID(for element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        let err = _AXUIElementGetWindow(element, &wid)
        return err == .success ? wid : nil
    }

    /// Get all CGWindowIDs for a given PID.
    public func windowIDs(forPID pid: pid_t) -> [CGWindowID] {
        return pidWindows[pid].map { Array($0) } ?? []
    }

    /// Store the expected frame after we apply geometry (for echo suppression).
    public func recordExpectedFrame(_ frame: NSRect, for id: CGWindowID) {
        expectedFrames[id] = frame
    }

    /// Check if an observed frame matches what we last applied (within tolerance).
    /// Returns true if it's likely an echo of our own resize/move.
    public func isEcho(_ frame: NSRect, for id: CGWindowID, tolerance: CGFloat = 2) -> Bool {
        guard let expected = expectedFrames[id] else { return false }
        return abs(frame.minX - expected.minX) < tolerance &&
               abs(frame.minY - expected.minY) < tolerance &&
               abs(frame.width - expected.width) < tolerance &&
               abs(frame.height - expected.height) < tolerance
    }

    /// Remove all state for a terminated PID.
    public func forget(pid: pid_t) {
        guard let ids = pidWindows[pid] else { return }
        for wid in ids {
            elements.removeValue(forKey: wid)
            expectedFrames.removeValue(forKey: wid)
        }
        pidWindows.removeValue(forKey: pid)
    }
}
