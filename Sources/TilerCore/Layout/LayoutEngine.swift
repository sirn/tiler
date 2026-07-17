import AppKit
import Foundation

public struct GapConfig: Equatable {
  public var outerGaps: CGFloat
  public var innerGaps: CGFloat
  public var columnGaps: CGFloat

  public init(outerGaps: CGFloat = 8, innerGaps: CGFloat = 6, columnGaps: CGFloat = 8) {
    self.outerGaps = outerGaps
    self.innerGaps = innerGaps
    self.columnGaps = columnGaps
  }
}

public enum LayoutEngine {

  /// Compute frames for all windows in a workspace, given screen geometry and gaps.
  /// Returns a dictionary of windowID → frame in screen coordinates.
  /// The `viewportOffset` shifts all columns horizontally to center the focused column.
  /// The `visibleRange` specifies which column indices are on-screen; others are placed off-screen.
  public static func layout(
    workspace: Workspace,
    screen: ScreenInfo,
    gaps: GapConfig,
    viewportOffset: CGFloat = 0,
    visibleRange: Range<Int>? = nil
  ) -> [CGWindowID: NSRect] {
    guard !workspace.columns.isEmpty else { return [:] }

    let visibleRange = visibleRange ?? 0..<workspace.columns.count

    let visibleFrame = screen.visibleFrame
    let og = gaps.outerGaps

    let usableRect = NSRect(
      x: visibleFrame.minX + og,
      y: visibleFrame.minY + og,
      width: max(0, visibleFrame.width - 2 * og),
      height: max(0, visibleFrame.height - 2 * og)
    )

    let cols = LayoutGeometry.columns(workspace, screen, gaps)

    tiler_debug(
      "[LayoutEngine] layout: \(workspace.columns.count) columns, viewportOffset=\(String(format: "%.1f", viewportOffset)), visibleRange=\(visibleRange)"
    )
    tiler_debug(
      "[LayoutEngine]   usableRect: x=\(String(format: "%.1f", usableRect.minX)) y=\(String(format: "%.1f", usableRect.minY)) w=\(String(format: "%.1f", usableRect.width)) h=\(String(format: "%.1f", usableRect.height))"
    )
    for i in cols.indices {
      let wf = workspace.columns[i].widthFraction
      tiler_debug(
        "[LayoutEngine]   col[\(i)] left=\(String(format: "%.1f", cols[i].left)) widthFraction=\(String(format: "%.3f", wf)) width=\(String(format: "%.1f", cols[i].width))"
      )
    }

    var result: [CGWindowID: NSRect] = [:]

    let screenMinX = visibleFrame.minX
    let screenMaxX = visibleFrame.maxX

    let roundedOffset = round(viewportOffset)
    for (colIndex, column) in workspace.columns.enumerated() {
      let isVisible = visibleRange.contains(colIndex)
      let colGeom = cols[colIndex]
      let colWidth = colGeom.width
      let colHeight = usableRect.height
      let columnX = round(usableRect.minX - roundedOffset + colGeom.left)
      let onScreen = isVisible

      // Determine which screen edge to park this column against when hidden.
      // A column whose strip left edge is before the viewport has scrolled off to the left;
      // otherwise it is off to the right. Leave exactly 1px on-screen so macOS honors
      // the position without clamping it to a ~40px sliver.
      // macOS AX clamps any window positioned so it would be fully off-screen, snapping it
      // back to roughly a 40px sliver. Leaving ≥1px visible is honored. This behavior is
      // empirically measured and undocumented — it may change across macOS versions.
      let offLeft = colGeom.left < roundedOffset
      let hiddenX = round(offLeft ? (screenMinX - colWidth + 1) : (screenMaxX - 1))

      tiler_debug(
        "[LayoutEngine]   col[\(colIndex)] x=\(String(format: "%.1f", columnX)) width=\(String(format: "%.1f", colWidth)) visible=\(isVisible) onScreen=\(onScreen)"
      )

      guard isVisible else {
        // Place off-screen with 1px on the correct screen edge so macOS honors the position
        for window in column.windows {
          result[window.id] = NSRect(
            x: hiddenX,
            y: usableRect.minY,
            width: colWidth,
            height: usableRect.height
          )
          tiler_debug(
            "[LayoutEngine]     window \(window.id) → off-screen frame (x=\(hiddenX), \(offLeft ? "left" : "right"))"
          )
        }
        continue
      }

      guard !column.windows.isEmpty else { continue }

      switch column.mode {
      case .stack:
        let totalGaps = gaps.innerGaps * CGFloat(column.windows.count - 1)
        let windowHeight = max(1, (colHeight - totalGaps) / CGFloat(column.windows.count))
        let effectiveHeight = max(windowHeight, column.measuredMinHeight ?? 0)
        // Cocoa y is bottom-origin; lay out the stack top-down so windows[0] is the
        // topmost window (matches the up/down action semantics, where index 0 = top).
        var windowY = usableRect.maxY - effectiveHeight

        for window in column.windows {
          let frame = NSRect(
            x: columnX,
            y: round(windowY),
            width: colWidth,
            height: round(effectiveHeight)
          )
          result[window.id] = frame
          tiler_debug(
            "[LayoutEngine]     window \(window.id) → frame(\(String(format: "%.1f", frame.minX)), \(String(format: "%.1f", frame.minY)), \(String(format: "%.1f", frame.width)), \(String(format: "%.1f", frame.height)))"
          )
          windowY -= effectiveHeight + gaps.innerGaps
        }

      case .tab:
        let titleBarHeight: CGFloat = 22
        let focusIdx = min(column.focusedWindowIndex, column.windows.count - 1)
        let count = column.windows.count
        // All windows share the same frame height: remaining space after accounting
        // for title bars of non-active windows that peek out above each other.
        let windowHeight = max(1, colHeight - CGFloat(count - 1) * titleBarHeight)

        var displayOrder = column.windows
        let focused = displayOrder.remove(at: focusIdx)
        displayOrder.append(focused)

        // Non-active windows: stacked behind, each offset by titleBarHeight so only
        // the title bar peeks above the window below it.
        for i in 0..<displayOrder.count - 1 {
          let belowCount = (displayOrder.count - 1) - i
          let y = usableRect.minY + CGFloat(belowCount) * titleBarHeight
          let frame = NSRect(
            x: columnX,
            y: round(y),
            width: colWidth,
            height: round(windowHeight)
          )
          result[displayOrder[i].id] = frame
          tiler_debug(
            "[LayoutEngine]     window \(displayOrder[i].id) (tab non-active) → frame(x=\(frame.minX), y=\(frame.minY), w=\(frame.width), h=\(frame.height))"
          )
        }

        let activeFrame = NSRect(
          x: columnX,
          y: usableRect.minY,
          width: colWidth,
          height: round(windowHeight)
        )
        result[focused.id] = activeFrame
        tiler_debug(
          "[LayoutEngine]     window \(focused.id) (tab active) → frame(x=\(activeFrame.minX), y=\(activeFrame.minY), w=\(activeFrame.width), h=\(activeFrame.height))"
        )
      }
    }

    return result
  }
}
