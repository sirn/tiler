import AppKit

public enum ViewportCalc {

    /// Compute the horizontal viewport offset that centers the focused column on screen.
    /// Returns 0 (no scroll) if there's only one column or total width fits on screen.
    public static func computeOffset(
        workspace: Workspace,
        screen: ScreenInfo,
        gaps: GapConfig
    ) -> CGFloat {
        guard !workspace.columns.isEmpty else { return 0 }

        let usableWidth = screen.visibleFrame.width - 2 * gaps.outerGaps

        // Calculate total width of all columns + gaps
        var totalWidth: CGFloat = 0
        for col in workspace.columns {
            totalWidth += usableWidth * col.widthFraction
        }
        totalWidth += gaps.columnGaps * CGFloat(max(0, workspace.columns.count - 1))

        // If everything fits, no scrolling
        if totalWidth <= screen.visibleFrame.width {
            return 0
        }

        // Calculate center of focused column
        var offset: CGFloat = 0
        for (i, col) in workspace.columns.enumerated() {
            let colWidth = usableWidth * col.widthFraction
            if i == workspace.focusedColumnIndex {
                let colCenter = offset + colWidth / 2
                // We want colCenter to be at screen center
                let viewportCenter = screen.visibleFrame.width / 2
                let scrollOffset = colCenter - viewportCenter
                return max(0, scrollOffset)
            }
            offset += colWidth + gaps.columnGaps
        }

        return 0
    }
}
