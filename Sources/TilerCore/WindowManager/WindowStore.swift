import AppKit
import ApplicationServices
import CoreGraphics

/// Owns the CGWindowID ↔ AXUIElement identity map, refreshed from CGWindowList.
/// Uses `_AXUIElementGetWindow` for exact identity, with position-based fallback when that fails.
public final class WindowStore {
    private var elements: [CGWindowID: AXUIElement] = [:]
    private var pidWindows: [pid_t: Set<CGWindowID>] = [:]
    private var expectedFrames: [CGWindowID: NSRect] = [:]

    /// Rebuild the identity map from CGWindowList + AX, with position-based fallback.
    public func refresh() {
        elements.removeAll(keepingCapacity: true)
        pidWindows.removeAll(keepingCapacity: true)

        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        // First pass: build CGWindowList info indexed by PID for fallback matching
        var cgWindowsByPID: [pid_t: [(wid: CGWindowID, bounds: NSRect, title: String)]] = [:]

        for info in windowInfo {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer <= 0 else { continue }

            let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            let bounds = NSRect(
                x: boundsDict?["X"] ?? 0,
                y: boundsDict?["Y"] ?? 0,
                width: boundsDict?["Width"] ?? 0,
                height: boundsDict?["Height"] ?? 0
            )
            let title = info[kCGWindowName as String] as? String ?? ""
            cgWindowsByPID[pid, default: []].append((wid, bounds, title))
        }

        // Second pass: iterate each PID and match via AX
        for (pid, cgWindows) in cgWindowsByPID {
            let appElement = AXUIElementCreateApplication(pid)
            var appWindows: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &appWindows)
            guard result == .success, let axWindows = appWindows as? [AXUIElement] else {
                // Can't get AX windows for this app — skip entirely
                continue
            }
            // Track which CGWindowIDs we've matched
            var matchedCG: Set<CGWindowID> = []

            // For each AX window, try _AXUIElementGetWindow first, then position fallback
            for axWindow in axWindows {
                var foundWid: CGWindowID = 0
                let err = _AXUIElementGetWindow(axWindow, &foundWid)

                if err == .success, foundWid != 0 {
                    // Exact match via private API
                    elements[foundWid] = axWindow
                    pidWindows[pid, default: []].insert(foundWid)
                    matchedCG.insert(foundWid)
                } else {
                    // Fallback: match by position
                    var axPos: CFTypeRef?, axSize: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &axPos) == .success,
                          AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &axSize) == .success,
                          CFGetTypeID(axPos) == AXValueGetTypeID(),
                          CFGetTypeID(axSize) == AXValueGetTypeID() else { continue }

                    let posAX = unsafeBitCast(axPos, to: AXValue.self)
                    let sizeAX = unsafeBitCast(axSize, to: AXValue.self)
                    var axPoint = CGPoint.zero
                    var axSizeVal = CGSize.zero
                    guard AXValueGetValue(posAX, .cgPoint, &axPoint),
                          AXValueGetValue(sizeAX, .cgSize, &axSizeVal) else { continue }

                    // AX position is top-left origin. CGWindowList bounds are also top-left origin.
                    // So we compare directly.
                    var bestMatch: (wid: CGWindowID, distance: CGFloat)?
                    for cgw in cgWindows where !matchedCG.contains(cgw.wid) {
                        let dx = abs(axPoint.x - cgw.bounds.minX)
                        let dy = abs(axPoint.y - cgw.bounds.minY)
                        let dw = abs(axSizeVal.width - cgw.bounds.width)
                        let dh = abs(axSizeVal.height - cgw.bounds.height)
                        let distance = dx + dy + dw + dh
                        if distance < 10 && (bestMatch == nil || distance < bestMatch!.distance) {
                            bestMatch = (cgw.wid, distance)
                        }
                    }
                    if let match = bestMatch {
                        elements[match.wid] = axWindow
                        pidWindows[pid, default: []].insert(match.wid)
                        matchedCG.insert(match.wid)
                    }
                }
            }

            // For CGWindowList entries that didn't match any AX window, try a secondary
            // fallback: iterate remaining unmatched windows and match by array order
            for cgw in cgWindows where !matchedCG.contains(cgw.wid) {
                // Try position matching against all ax windows (not already matched)
                // with a wider tolerance
                var axPos: CFTypeRef?, axSize: CFTypeRef?
                for axWindow in axWindows {
                    AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &axPos)
                    AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &axSize)
                    guard let pos = axPos, let size = axSize,
                          CFGetTypeID(pos) == AXValueGetTypeID(),
                          CFGetTypeID(size) == AXValueGetTypeID() else { continue }
                    let posAX = unsafeBitCast(pos, to: AXValue.self)
                    let sizeAX = unsafeBitCast(size, to: AXValue.self)
                    var axPoint = CGPoint.zero
                    var axSizeVal = CGSize.zero
                    guard AXValueGetValue(posAX, .cgPoint, &axPoint),
                          AXValueGetValue(sizeAX, .cgSize, &axSizeVal) else { continue }

                    if abs(axPoint.x - cgw.bounds.minX) < 2 &&
                       abs(axPoint.y - cgw.bounds.minY) < 2 &&
                       abs(axSizeVal.width - cgw.bounds.width) < 2 &&
                       abs(axSizeVal.height - cgw.bounds.height) < 2 {
                        // Check if this AX window is already matched to a different CG window
                        var alreadyMatched = false
                        for (_, existingElement) in elements {
                            if existingElement === axWindow {
                                alreadyMatched = true
                                break
                            }
                        }
                        if !alreadyMatched {
                            elements[cgw.wid] = axWindow
                            pidWindows[pid, default: []].insert(cgw.wid)
                            matchedCG.insert(cgw.wid)
                        }
                    }
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
