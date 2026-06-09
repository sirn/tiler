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

    // Column width is proportional to widthFraction (CSS flex-grow style).
    // Fractions do NOT need to sum to 1.0: they are normalized by totalWeight.
    // E.g. three columns of 0.5 each (totalWeight=1.5) each get 1/3 of the
    // available content space, filling the viewport exactly.
    let totalWeight = workspace.columns.reduce(0.0) { $0 + $1.widthFraction }
    let totalContent = U - CGFloat(N - 1) * gaps.columnGaps

    guard totalWeight > 0, totalContent > 0 else {
      let w = totalWeight <= 0 ? U / CGFloat(N) : min(U, totalContent) / CGFloat(N)
      var result: [ColumnLayout] = []
      var x: CGFloat = 0
      for i in 0..<N {
        result.append(ColumnLayout(left: x, width: w))
        if i < N - 1 { x += w + gaps.columnGaps }
      }
      return result
    }

    // Round each column's ideal width to nearest integer (avoids float drift).
    // Absorb measured min-width so windows with OS-enforced minimums stay usable.
    var result: [ColumnLayout] = []
    var x: CGFloat = 0
    for (i, col) in workspace.columns.enumerated() {
      let requested = round(totalContent * col.widthFraction / totalWeight)
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
