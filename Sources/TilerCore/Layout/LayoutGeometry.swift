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

    public static func columns(_ workspace: Workspace, _ screen: ScreenInfo, _ gaps: GapConfig) -> [ColumnLayout] {
        let N = workspace.columns.count
        guard N > 0 else { return [] }
        let U = usableWidth(screen, gaps)
        // Column width is a fraction of (U minus one column gap), independent of total
        // column count. Fractions summing to 1.0 exactly fill the viewport: two 0.5
        // columns plus one gap == U, leaving symmetric outer margins.
        let widthBase = U - gaps.columnGaps
        guard widthBase > 0 else {
            // Degenerate: not enough space for gaps, give each column equal share of U
            let w = U / CGFloat(N)
            var result: [ColumnLayout] = []
            var x: CGFloat = 0
            for _ in 0..<N {
                result.append(ColumnLayout(left: x, width: w))
                x += w
            }
            return result
        }

        // Round each column's ideal width to nearest integer (avoids float drift).
        // Absorb measured min-width so windows with OS-enforced minimums stay usable.
        var result: [ColumnLayout] = []
        var x: CGFloat = 0
        for (i, col) in workspace.columns.enumerated() {
            let requested = round(widthBase * col.widthFraction)
            let w = max(requested, col.measuredMinWidth ?? 0)
            result.append(ColumnLayout(left: x, width: w))
            if i < N - 1 {
                x += w + gaps.columnGaps
            }
        }
        return result
    }

    public static func contentWidth(_ cols: [ColumnLayout]) -> CGFloat {
        cols.last.map { $0.right } ?? 0
    }
}