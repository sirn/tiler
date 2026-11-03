import AppKit

public struct ColumnLayout {
  public let left: CGFloat
  public let width: CGFloat
  public var right: CGFloat { left + width }
}

public enum LayoutGeometry {
  public static func usableWidth(_ screen: ScreenInfo, _ gaps: GapConfig) -> CGFloat {
    max(0, screen.visibleFrame.width - 2 * gaps.outerGaps)
  }

  /// Returns the proportion that `columns` resolves to `width`, or nil when the
  /// screen has no usable width.
  public static func proportion(forWidth width: CGFloat, _ screen: ScreenInfo, _ gaps: GapConfig)
    -> CGFloat?
  {
    let U = usableWidth(screen, gaps)
    guard U > 0 else { return nil }
    return (width + gaps.columnGaps) / (U + gaps.columnGaps)
  }

  public static func columns(_ workspace: Workspace, _ screen: ScreenInfo, _ gaps: GapConfig)
    -> [ColumnLayout]
  {
    let N = workspace.columns.count
    guard N > 0 else { return [] }
    let U = usableWidth(screen, gaps)

    // Width resolution mirrors Niri: a proportion is a share of the slot width (the
    // usable width plus one gap), and each column keeps one gap for itself. The gaps
    // a proportion gives up become the gaps between columns, so proportions that add
    // up to 1 fill the usable width exactly. Fixed widths are absolute, so a column
    // for a window that cannot resize keeps its size and the rest overflow.
    // Proportions are not normalized: they overflow the viewport when they add up to
    // more than 1. Rounding the cumulative slot end rather than each width keeps the
    // widths summing to the rounded total, so rounding never adds or drops a pixel.
    let gap = gaps.columnGaps
    let slotWidth = U + gap

    var result: [ColumnLayout] = []
    var x: CGFloat = 0
    var slot: CGFloat = 0
    var proportion: CGFloat = 0
    var runStartSlot: CGFloat = 0
    var runStartProportion: CGFloat = 0
    for (i, col) in workspace.columns.enumerated() {
      let previousSlot = slot
      switch col.width {
      case .proportion(let p):
        proportion += p
        slot = runStartSlot + round(slotWidth * (proportion - runStartProportion))
      case .fixed(let width):
        slot = previousSlot + width + gap
        runStartSlot = slot
        runStartProportion = proportion
      }
      let requested = max(0, slot - previousSlot - gap)
      let w = max(requested, col.measuredMinWidth ?? 0)
      result.append(ColumnLayout(left: x, width: w))
      if i < N - 1 { x += w + gap }
    }
    return result
  }

  public static func contentWidth(_ cols: [ColumnLayout]) -> CGFloat {
    cols.last.map { $0.right } ?? 0
  }
}
