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

  public static func columns(_ workspace: Workspace, _ screen: ScreenInfo, _ gaps: GapConfig)
    -> [ColumnLayout]
  {
    let N = workspace.columns.count
    guard N > 0 else { return [] }
    let U = usableWidth(screen, gaps)

    // widthFraction is an absolute proportion of U: 0.5 = 50% of viewport width.
    // Fractions are not normalized — columns overflow the viewport, enabling scrolling.
    var result: [ColumnLayout] = []
    var x: CGFloat = 0
    for (i, col) in workspace.columns.enumerated() {
      let requested = round(U * col.widthFraction)
      let w = max(requested, col.measuredMinWidth ?? 0)
      result.append(ColumnLayout(left: x, width: w))
      if i < N - 1 { x += w + gaps.columnGaps }
    }
    return result
  }

  public static func contentWidth(_ cols: [ColumnLayout]) -> CGFloat {
    cols.last.map { $0.right } ?? 0
  }
}
