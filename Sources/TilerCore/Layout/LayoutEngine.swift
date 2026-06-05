import AppKit

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
    public static func layout(
        workspace: Workspace,
        screen: ScreenInfo,
        gaps: GapConfig,
        viewportOffset: CGFloat = 0
    ) -> [CGWindowID: NSRect] {
        guard !workspace.columns.isEmpty else { return [:] }

        let visibleFrame = screen.visibleFrame
        let og = gaps.outerGaps

        // Usable area after outer gaps
        let usableRect = NSRect(
            x: visibleFrame.minX + og,
            y: visibleFrame.minY + og,
            width: max(0, visibleFrame.width - 2 * og),
            height: max(0, visibleFrame.height - 2 * og)
        )

        var result: [CGWindowID: NSRect] = [:]
        var columnX: CGFloat = usableRect.minX - viewportOffset

        for column in workspace.columns {
            guard !column.windows.isEmpty else {
                columnX += usableRect.width * column.widthFraction + gaps.columnGaps
                continue
            }

            let colWidth = usableRect.width * column.widthFraction
            let colHeight = usableRect.height

            switch column.mode {
            case .stack:
                let windowHeight = (colHeight - gaps.innerGaps * CGFloat(column.windows.count - 1))
                    / CGFloat(column.windows.count)
                var windowY: CGFloat = usableRect.minY

                for window in column.windows {
                    let frame = NSRect(
                        x: columnX,
                        y: windowY,
                        width: colWidth,
                        height: windowHeight
                    )
                    result[window.id] = frame
                    windowY += windowHeight + gaps.innerGaps
                }

            case .tab:
                // In tab mode, only the focused window is on-screen at full column size
                let focusIdx = min(column.focusedWindowIndex, column.windows.count - 1)
                for (index, window) in column.windows.enumerated() {
                    if index == focusIdx {
                        result[window.id] = NSRect(
                            x: columnX,
                            y: usableRect.minY,
                            width: colWidth,
                            height: colHeight
                        )
                    } else {
                        // Off-screen: move far left
                        result[window.id] = NSRect(
                            x: -100000,
                            y: 0,
                            width: colWidth,
                            height: colHeight
                        )
                    }
                }
            }

            columnX += colWidth + gaps.columnGaps
        }

        return result
    }
}
