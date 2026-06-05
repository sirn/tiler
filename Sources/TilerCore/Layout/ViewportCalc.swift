import AppKit

public enum ViewportCalc {

    /// Compute the horizontal viewport offset that centers the focused column on screen.
    /// Returns 0 (no scroll) if total content width fits within the usable area.
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

        // If everything fits in the usable area, no scrolling
        let maxScroll = max(0, totalWidth - usableWidth)
        guard maxScroll > 0 else { return 0 }

        // Calculate center of focused column and derive scroll offset
        var contentOffset: CGFloat = 0
        for (i, col) in workspace.columns.enumerated() {
            let colWidth = usableWidth * col.widthFraction
            if i == workspace.focusedColumnIndex {
                let colCenter = contentOffset + colWidth / 2
                let scrollOffset = gaps.outerGaps + colCenter - screen.visibleFrame.width / 2
                return min(max(0, scrollOffset), maxScroll)
            }
            contentOffset += colWidth + gaps.columnGaps
        }

        return 0
    }
}
