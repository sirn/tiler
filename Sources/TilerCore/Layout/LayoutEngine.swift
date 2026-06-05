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

        // Usable area after outer gaps
        let usableRect = NSRect(
            x: visibleFrame.minX + og,
            y: visibleFrame.minY + og,
            width: max(0, visibleFrame.width - 2 * og),
            height: max(0, visibleFrame.height - 2 * og)
        )

        let cols = LayoutGeometry.columns(workspace, screen, gaps)

        // ── [LayoutEngine] Debug logging ──
        tiler_log("[LayoutEngine] layout: \(workspace.columns.count) columns, viewportOffset=\(String(format: "%.1f", viewportOffset)), visibleRange=\(visibleRange)")
        tiler_log("[LayoutEngine]   usableRect: x=\(String(format: "%.1f", usableRect.minX)) y=\(String(format: "%.1f", usableRect.minY)) w=\(String(format: "%.1f", usableRect.width)) h=\(String(format: "%.1f", usableRect.height))")
        for i in cols.indices {
            let wf = workspace.columns[i].widthFraction
            tiler_log("[LayoutEngine]   col[\(i)] left=\(String(format: "%.1f", cols[i].left)) widthFraction=\(String(format: "%.3f", wf)) width=\(String(format: "%.1f", cols[i].width))")
        }

        var result: [CGWindowID: NSRect] = [:]

        for (colIndex, column) in workspace.columns.enumerated() {
            let isVisible = visibleRange.contains(colIndex)
            let colGeom = cols[colIndex]
            let colWidth = colGeom.width
            let colHeight = usableRect.height
            let columnX = usableRect.minX - viewportOffset + colGeom.left
            let onScreen = isVisible

            // ── [LayoutEngine] Per-column logging ──
            tiler_log("[LayoutEngine]   col[\(colIndex)] x=\(String(format: "%.1f", columnX)) width=\(String(format: "%.1f", colWidth)) visible=\(isVisible) onScreen=\(onScreen)")

            guard isVisible else {
                for window in column.windows {
                    result[window.id] = NSRect(x: -100000, y: 0, width: colWidth, height: usableRect.height)
                    tiler_log("[LayoutEngine]     window \(window.id) → off-screen frame")
                }
                continue
            }

            guard !column.windows.isEmpty else { continue }

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
                    tiler_log("[LayoutEngine]     window \(window.id) → frame(\(String(format: "%.1f", frame.minX)), \(String(format: "%.1f", frame.minY)), \(String(format: "%.1f", frame.width)), \(String(format: "%.1f", frame.height)))")
                    windowY += windowHeight + gaps.innerGaps
                }

            case .tab:
                // In tab mode, only the focused window is on-screen at full column size
                let focusIdx = min(column.focusedWindowIndex, column.windows.count - 1)
                for (index, window) in column.windows.enumerated() {
                    if index == focusIdx {
                        let frame = NSRect(
                            x: columnX,
                            y: usableRect.minY,
                            width: colWidth,
                            height: colHeight
                        )
                        result[window.id] = frame
                        tiler_log("[LayoutEngine]     window \(window.id) (tab focused) → frame(\(String(format: "%.1f", frame.minX)), \(String(format: "%.1f", frame.minY)), \(String(format: "%.1f", frame.width)), \(String(format: "%.1f", frame.height)))")
                    } else {
                        // Off-screen: move far left
                        let frame = NSRect(
                            x: -100000,
                            y: 0,
                            width: colWidth,
                            height: colHeight
                        )
                        result[window.id] = frame
                        tiler_log("[LayoutEngine]     window \(window.id) (tab hidden) → off-screen frame")
                    }
                }
            }
        }

        return result
    }
}