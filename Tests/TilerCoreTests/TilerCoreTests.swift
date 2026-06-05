import XCTest
@testable import TilerCore

final class TilerCoreTests: XCTestCase {
    func testWorkspaceInit() {
        let workspace = Workspace(id: 1)
        XCTAssertEqual(workspace.id, 1)
        XCTAssertTrue(workspace.columns.isEmpty)
        XCTAssertEqual(workspace.focusedColumnIndex, 0)
    }

    // MARK: - Helpers

    private func makeScreen(width: CGFloat = 1000) -> ScreenInfo {
        ScreenInfo(
            id: 1,
            frame: NSRect(x: 0, y: 0, width: width, height: 800),
            visibleFrame: NSRect(x: 0, y: 0, width: width, height: 800)
        )
    }

    private func makeGaps(column: CGFloat = 8) -> GapConfig {
        GapConfig(outerGaps: 0, innerGaps: 6, columnGaps: column)
    }

    private func makeWorkspace(fractions: [CGFloat], focus: Int) -> Workspace {
        let cols = fractions.map { Column(widthFraction: $0) }
        return Workspace(id: 1, columns: cols, focusedColumnIndex: focus)
    }

    // MARK: - ViewportCalc tests

    // N=3, 0.5 fracs, focus col 2, starting from offset 0:
    // right-flush brings col 2's right edge to U; visibleRange is derived from
    // the final offset (not a pre-clamp page start).
    func testScrollRightNoSpill() {
        let ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 2)
        let screen = makeScreen()
        let gaps = makeGaps()
        let (offset, range) = ViewportCalc.computeOffset(
            workspace: ws, screen: screen, gaps: gaps, currentOffset: 0)
        XCTAssertEqual(offset, 492, accuracy: 0.5)
        XCTAssertEqual(range, 1..<3)
        // Last visible column's right edge must not exceed U
        let cols = LayoutGeometry.columns(ws, screen, gaps)
        let rightEdge = cols[range.upperBound - 1].right - offset
        XCTAssertLessThanOrEqual(rightEdge, 1000 + 0.5)
    }

    // N=3, 0.5 fracs, focus col 1, already visible at offset 0 -> lazy, no scroll.
    func testLazyFocusAlreadyVisible() {
        let ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 1)
        let (offset, range) = ViewportCalc.computeOffset(
            workspace: ws, screen: makeScreen(), gaps: makeGaps(), currentOffset: 0)
        XCTAssertEqual(offset, 0, accuracy: 0.5)
        XCTAssertTrue(range.contains(1))
    }

    // N=3, 0.5 fracs, focus col 0, current offset 492 (rightmost scroll):
    // focus is left of vis={1,2} -> left-flush -> offset=0, col 0 visible.
    func testScrollLeftFlush() {
        let ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 0)
        let (offset, range) = ViewportCalc.computeOffset(
            workspace: ws, screen: makeScreen(), gaps: makeGaps(), currentOffset: 492)
        XCTAssertEqual(offset, 0, accuracy: 0.5)
        XCTAssertTrue(range.contains(0))
    }

    // N=4, all frac=0.7: no two columns fit together.
    // Focus col 3 (last) from offset 0 -> right-flush: col 3's right edge flushes to U.
    func testDegenerateWideColumnRightFlush() {
        let ws = makeWorkspace(fractions: [0.7, 0.7, 0.7, 0.7], focus: 3)
        let screen = makeScreen()
        let gaps = makeGaps()
        let (offset, range) = ViewportCalc.computeOffset(
            workspace: ws, screen: screen, gaps: gaps, currentOffset: 0)
        // With U=1000, avail=976, w=683: col3.right=2756, offset=1756
        XCTAssertEqual(offset, 1756, accuracy: 1.0)
        // Only focused column fits (0.7 frac = ~683 > half of U)
        XCTAssertEqual(range, 3..<4)
        // Right-flush: focused column's right edge must equal U within tolerance
        let cols = LayoutGeometry.columns(ws, screen, gaps)
        XCTAssertEqual(cols[3].right - offset, 1000, accuracy: 1.0)
    }

    // MARK: - LayoutEngine / geometry consistency test

    // End-to-end: ViewportCalc + LayoutEngine must never place an on-screen window
    // whose right edge exceeds the usable area (no spill regardless of which column
    // is focused or what the starting offset is).
    func testLayoutNoWindowSpill() {
        let win0 = WindowNode(id: 1, pid: 1, title: "w0")
        let win1 = WindowNode(id: 2, pid: 1, title: "w1")
        let win2 = WindowNode(id: 3, pid: 1, title: "w2")
        let ws = Workspace(id: 1, columns: [
            Column(windows: [win0], widthFraction: 0.5),
            Column(windows: [win1], widthFraction: 0.5),
            Column(windows: [win2], widthFraction: 0.5),
        ], focusedColumnIndex: 2)
        let screen = makeScreen()
        let gaps = makeGaps()
        let (offset, visibleRange) = ViewportCalc.computeOffset(
            workspace: ws, screen: screen, gaps: gaps, currentOffset: 0)
        let frames = LayoutEngine.layout(
            workspace: ws, screen: screen, gaps: gaps,
            viewportOffset: offset, visibleRange: visibleRange)
        for (id, frame) in frames {
            guard frame.minX > -99000 else { continue }  // skip off-screen placements
            XCTAssertLessThanOrEqual(
                frame.maxX, screen.visibleFrame.maxX + 0.5,
                "Window \(id) spills right: frame=\(frame)")
        }
    }
}