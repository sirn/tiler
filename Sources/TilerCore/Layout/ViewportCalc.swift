import AppKit
import Foundation

public enum ViewportCalc {
    private static let epsilon: CGFloat = 0.5

    /// Compute viewport offset and visible range using viewport-first packing.
    ///
    /// - Rightward navigation (focus > old visible): pack from LEFT edge, starting with focused column, expanding right.
    /// - Leftward navigation (focus < old visible): pack from RIGHT edge, starting with focused column, expanding left.
    /// - No navigation (focus in old visible): keep current offset (lazy).
    ///
    /// Returns (offset, visibleRange) where visibleRange contains ONLY columns that fully fit.
    public static func computeOffset(
        workspace: Workspace,
        screen: ScreenInfo,
        gaps: GapConfig,
        currentOffset: CGFloat = 0
    ) -> (offset: CGFloat, visibleRange: Range<Int>) {
        let cols = LayoutGeometry.columns(workspace, screen, gaps)
        let N = cols.count
        guard N > 0 else { return (currentOffset, 0..<0) }

        let U = LayoutGeometry.usableWidth(screen, gaps)
        let W = LayoutGeometry.contentWidth(cols)
        let maxScroll = max(0, W - U)

        tiler_log("[ViewportCalc] computeOffset: \(N) columns, U=\(String(format: "%.1f", U)), W=\(String(format: "%.1f", W)), maxScroll=\(String(format: "%.1f", maxScroll))")
        for i in cols.indices {
            let wf = workspace.columns[i].widthFraction
            tiler_log("[ViewportCalc]   col[\(i)] left=\(String(format: "%.1f", cols[i].left)) right=\(String(format: "%.1f", cols[i].right)) width=\(String(format: "%.1f", cols[i].width)) frac=\(String(format: "%.3f", wf))")
        }
        tiler_log("[ViewportCalc]   currentOffset=\(String(format: "%.1f", currentOffset))")

        guard maxScroll > epsilon else {
            tiler_log("[ViewportCalc]   no scroll needed, returning offset=0, visibleRange=0..<\(N)")
            return (0, 0..<N)
        }

        let f = min(workspace.focusedColumnIndex, N - 1)
        let s0 = min(max(0, currentOffset), maxScroll)
        let oldVisible = visibleAtOffset(cols, s0, U)

        tiler_log("[ViewportCalc]   focusedColumn=\(f), clampedOffset=\(String(format: "%.1f", s0)), oldVisible=\(oldVisible)")

        let offset: CGFloat
        let newVisible: Range<Int>

        if oldVisible.contains(f) {
            // Lazy: focus already fully visible, no scroll
            offset = s0
            newVisible = oldVisible
            tiler_log("[ViewportCalc]   LAZY: focus in \(oldVisible), offset=\(String(format: "%.1f", offset))")
        } else if f > oldVisible.upperBound {
            // RIGHTWARD navigation: focus is to the right of old visible range
            // Pack from LEFT edge: start with focused col left at 0, expand RIGHT while fitting
            (offset, newVisible) = packFromLeft(cols: cols, focusedIndex: f, U: U, maxScroll: maxScroll)
            tiler_log("[ViewportCalc]   RIGHTWARD: pack from left edge, offset=\(String(format: "%.1f", offset)), visible=\(newVisible)")
        } else {
            // LEFTWARD navigation: focus is to the left of old visible range
            // Pack from RIGHT edge: start with focused col right at U, expand LEFT while fitting
            (offset, newVisible) = packFromRight(cols: cols, focusedIndex: f, U: U, maxScroll: maxScroll)
            tiler_log("[ViewportCalc]   LEFTWARD: pack from right edge, offset=\(String(format: "%.1f", offset)), visible=\(newVisible)")
        }

        // Clamp to exact edges near boundaries
        let clampedOffset = clampToEdge(offset, maxScroll)
        let finalVisible = visibleAtOffset(cols, clampedOffset, U)

        tiler_log("[ViewportCalc]   RESULT: offset=\(String(format: "%.1f", clampedOffset)), visibleRange=\(finalVisible)")
        return (clampedOffset, finalVisible)
    }

    /// Pack columns starting from focused column at LEFT edge (0), expanding RIGHT.
    /// Returns (offset, visibleRange) where visibleRange is contiguous and all columns fully fit.
    private static func packFromLeft(
        cols: [ColumnLayout], focusedIndex: Int, U: CGFloat, maxScroll: CGFloat
    ) -> (CGFloat, Range<Int>) {
        // Left-flush the focused column
        let initialOffset = cols[focusedIndex].left
        var offset = min(max(0, initialOffset), maxScroll)

        // Clamp exactly at 0 if near it
        if offset <= epsilon { offset = 0 }

        // Find all columns that fully fit in [offset, offset+U]
        var lo = focusedIndex
        var hi = focusedIndex
        for i in (0..<focusedIndex).reversed() {
            if cols[i].left >= offset - epsilon && cols[i].right <= offset + U + epsilon {
                lo = i
            } else { break }
        }
        for i in (focusedIndex + 1)..<cols.count {
            if cols[i].left >= offset - epsilon && cols[i].right <= offset + U + epsilon {
                hi = i
            } else { break }
        }

        return (offset, lo..<(hi + 1))
    }

    /// Pack columns starting from focused column at RIGHT edge (U), expanding LEFT.
    /// Returns (offset, visibleRange) where visibleRange is contiguous and all columns fully fit.
    private static func packFromRight(
        cols: [ColumnLayout], focusedIndex: Int, U: CGFloat, maxScroll: CGFloat
    ) -> (CGFloat, Range<Int>) {
        // Right-flush the focused column
        let initialOffset = cols[focusedIndex].right - U
        var offset = min(max(0, initialOffset), maxScroll)

        // Clamp exactly at maxScroll if near it
        if offset >= maxScroll - epsilon { offset = maxScroll }

        // Find all columns that fully fit in [offset, offset+U]
        var lo = focusedIndex
        var hi = focusedIndex
        for i in (0..<focusedIndex).reversed() {
            if cols[i].left >= offset - epsilon && cols[i].right <= offset + U + epsilon {
                lo = i
            } else { break }
        }
        for i in (focusedIndex + 1)..<cols.count {
            if cols[i].left >= offset - epsilon && cols[i].right <= offset + U + epsilon {
                hi = i
            } else { break }
        }

        return (offset, lo..<(hi + 1))
    }

    /// Full-containment visible check at given offset.
    private static func visibleAtOffset(_ cols: [ColumnLayout], _ s: CGFloat, _ U: CGFloat) -> Range<Int> {
        let viewportRight = s + U
        var lo = cols.count
        var hi = -1
        for i in cols.indices {
            let leftOK = cols[i].left >= s - epsilon
            let rightOK = cols[i].right <= viewportRight + epsilon
            if leftOK && rightOK {
                if i < lo { lo = i }
                hi = i
            }
        }
        return hi >= lo ? lo..<(hi + 1) : 0..<0
    }

    private static func clampToEdge(_ offset: CGFloat, _ maxScroll: CGFloat) -> CGFloat {
        if offset <= epsilon { return 0 }
        if offset >= maxScroll - epsilon { return maxScroll }
        return offset
    }
}