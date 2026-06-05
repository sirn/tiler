import AppKit
import ApplicationServices
import CoreGraphics

/// Owns the CGWindowID ↔ AXUIElement identity map, refreshed from CGWindowList.
/// Uses `axGetWindowID` for exact identity, with position-based fallback when that fails.
public final class WindowStore {
  private var elements: [CGWindowID: AXUIElement] = [:]
  private var pidWindows: [pid_t: Set<CGWindowID>] = [:]

  /// Rebuild the identity map from CGWindowList + AX, with position-based fallback.
  /// managedPIDs is unioned with the on-screen CGWindowList pids so that parked managed
  /// windows (off the current CGWindowList) are still resolved via AX identity.
  public func refresh(windowList: [[String: Any]]? = nil, managedPIDs: Set<pid_t> = []) {
    guard let windowInfo = windowList
      ?? CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else {
      return
    }
    elements.removeAll(keepingCapacity: true)
    pidWindows.removeAll(keepingCapacity: true)

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

    // Union: also process managed pids not in the on-screen CG list
    let allPIDs = Set(cgWindowsByPID.keys).union(managedPIDs)

    // Second pass: iterate each PID and match via AX
    for pid in allPIDs {
      let cgWindows = cgWindowsByPID[pid] ?? []
      let appElement = AXUIElementCreateApplication(pid)
      var appWindows: CFTypeRef?
      let result = AXUIElementCopyAttributeValue(
        appElement, kAXWindowsAttribute as CFString, &appWindows)
      guard result == .success, let axWindows = appWindows as? [AXUIElement] else {
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "unknown"
        tiler_debug(
          "WindowStore: PID \(pid) (\(appName)) - failed to get AX windows: result=\(result.rawValue), CG windows=\(cgWindows.count)"
        )
        // Fallback: try matching CG windows by position only using app children
        var appChildren: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXChildrenAttribute as CFString, &appChildren)
          == .success,
          let children = appChildren as? [AXUIElement]
        {
          var fallbackMatched: Set<CGWindowID> = []
          for child in children {
            var childPos: CFTypeRef?
            guard
              AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &childPos)
                == .success,
              CFGetTypeID(childPos) == AXValueGetTypeID()
            else { continue }
            let posAX = unsafeBitCast(childPos, to: AXValue.self)
            var childPoint = CGPoint.zero
            guard AXValueGetValue(posAX, .cgPoint, &childPoint) else { continue }

            var bestMatch: (wid: CGWindowID, distance: CGFloat)?
            for cgw in cgWindows where !fallbackMatched.contains(cgw.wid) {
              let dx = abs(childPoint.x - cgw.bounds.minX)
              let dy = abs(childPoint.y - cgw.bounds.minY)
              let distance = dx + dy
              if distance < 20 && (bestMatch == nil || distance < bestMatch!.distance) {
                bestMatch = (cgw.wid, distance)
              }
            }
            if let match = bestMatch {
              elements[match.wid] = child
              pidWindows[pid, default: []].insert(match.wid)
              fallbackMatched.insert(match.wid)
            }
          }
          tiler_debug(
            "WindowStore: PID \(pid) - position-only fallback matched \(fallbackMatched.count)/\(cgWindows.count) CG windows"
          )
        }
        continue
      }
      tiler_debug(
        "WindowStore: PID \(pid) - found \(axWindows.count) AX windows, \(cgWindows.count) CG windows"
      )
      // Track which CGWindowIDs we've matched
      var matchedCG: Set<CGWindowID> = []

      // Position-heuristic fallbacks are only safe when there's at most one AX window
      // for this pid. With multiple windows, heuristics can silently swap identities
      // while a window is mid-move, causing frames to be applied to the wrong element.
      let allowPositionFallback = axWindows.count <= 1

      // For each AX window, try axGetWindowID first, then position fallback.
      // axGetWindowID resolves the private SPI at runtime so the app doesn't crash
      // if Apple removes the symbol.
      for axWindow in axWindows {
        if let foundWid = axGetWindowID(axWindow) {
          // Exact match via runtime-resolved private API
          elements[foundWid] = axWindow
          pidWindows[pid, default: []].insert(foundWid)
          matchedCG.insert(foundWid)
        } else if allowPositionFallback && !cgWindows.isEmpty {
          // Fallback: match by position (only when this pid has exactly one AX window)
          var axPos: CFTypeRef?
          var axSize: CFTypeRef?
          guard
            AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &axPos)
              == .success,
            AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &axSize)
              == .success,
            CFGetTypeID(axPos) == AXValueGetTypeID(),
            CFGetTypeID(axSize) == AXValueGetTypeID()
          else { continue }

          let posAX = unsafeBitCast(axPos, to: AXValue.self)
          let sizeAX = unsafeBitCast(axSize, to: AXValue.self)
          var axPoint = CGPoint.zero
          var axSizeVal = CGSize.zero
          guard AXValueGetValue(posAX, .cgPoint, &axPoint),
            AXValueGetValue(sizeAX, .cgSize, &axSizeVal)
          else { continue }

          // AX position is top-left origin. CGWindowList bounds are also top-left origin.
          // So we compare directly.
          var bestMatch: (wid: CGWindowID, distance: CGFloat)?
          for cgw in cgWindows where !matchedCG.contains(cgw.wid) {
            let dx = abs(axPoint.x - cgw.bounds.minX)
            let dy = abs(axPoint.y - cgw.bounds.minY)
            let dw = abs(axSizeVal.width - cgw.bounds.width)
            let dh = abs(axSizeVal.height - cgw.bounds.height)
            let distance = dx + dy + dw + dh
            if distance < 20 && (bestMatch == nil || distance < bestMatch!.distance) {
              bestMatch = (cgw.wid, distance)
            }
          }
          if let match = bestMatch {
            elements[match.wid] = axWindow
            pidWindows[pid, default: []].insert(match.wid)
            matchedCG.insert(match.wid)
          }
        }
        // When allowPositionFallback is false and exact id lookup failed, skip this
        // window — it will be picked up once axGetWindowID succeeds
      }

      // Secondary fallback: only for single-window apps where the primary pass missed
      if allowPositionFallback {
        for cgw in cgWindows where !matchedCG.contains(cgw.wid) {
          var axPos: CFTypeRef?
          var axSize: CFTypeRef?
          for axWindow in axWindows {
            AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &axPos)
            AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &axSize)
            guard let pos = axPos, let size = axSize,
              CFGetTypeID(pos) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID()
            else { continue }
            let posAX = unsafeBitCast(pos, to: AXValue.self)
            let sizeAX = unsafeBitCast(size, to: AXValue.self)
            var axPoint = CGPoint.zero
            var axSizeVal = CGSize.zero
            guard AXValueGetValue(posAX, .cgPoint, &axPoint),
              AXValueGetValue(sizeAX, .cgSize, &axSizeVal)
            else { continue }

            if abs(axPoint.x - cgw.bounds.minX) < 2 && abs(axPoint.y - cgw.bounds.minY) < 2
              && abs(axSizeVal.width - cgw.bounds.width) < 2
              && abs(axSizeVal.height - cgw.bounds.height) < 2
            {
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
  }

  /// Get the AXUIElement for a CGWindowID.
  public func element(for id: CGWindowID) -> AXUIElement? {
    return elements[id]
  }

  /// Resolve the AXUIElement for a specific (pid, wid) by scanning the app's current AX
  /// windows. Used when the cached map may be stale, e.g. just after a native tab switch.
  public func liveElement(forPID pid: pid_t, wid: CGWindowID) -> AXUIElement? {
    let appElement = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        == .success,
      let axWindows = windowsRef as? [AXUIElement]
    else { return nil }
    for axWindow in axWindows {
      var w: CGWindowID = 0
      if _AXUIElementGetWindow(axWindow, &w) == .success, w == wid {
        return axWindow
      }
    }
    return nil
  }

  /// Get the CGWindowID for an AXUIElement via axGetWindowID.
  public func windowID(for element: AXUIElement) -> CGWindowID? {
    return axGetWindowID(element)
  }

  /// Remove all state for a terminated PID.
  public func forget(pid: pid_t) {
    guard let ids = pidWindows[pid] else { return }
    for wid in ids {
      elements.removeValue(forKey: wid)
    }
    pidWindows.removeValue(forKey: pid)
  }
}
