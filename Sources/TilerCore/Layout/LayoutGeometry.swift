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
        let availableWidth = U - gaps.columnGaps * CGFloat(N - 1)
        guard availableWidth > 0 else {
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

        // Round each column's ideal width to nearest integer (avoids float drift)
        var result: [ColumnLayout] = []
        var x: CGFloat = 0
        for (i, col) in workspace.columns.enumerated() {
            let idealWidth = availableWidth * col.widthFraction
            let w = round(idealWidth)
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