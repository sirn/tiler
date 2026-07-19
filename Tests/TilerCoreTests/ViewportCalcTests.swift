import XCTest

@testable import TilerCore

final class ViewportCalcTests: XCTestCase {

  // N=3, 0.5 fracs (absolute): each col=500, content overflows (1516 > 1000).
  // Focused col 2 forces scroll right. offset=516, visibleRange=1..<3 (any-part-visible).
  func testScrollRightNoSpill() {
    let ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 2)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, range) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U)
    XCTAssertEqual(offset, 516, accuracy: 0.5)
    XCTAssertEqual(range, 1..<3)
    // Last visible column's right edge must not exceed U
    let rightEdge = cols[range.upperBound - 1].right - offset
    XCTAssertEqual(rightEdge, 1000, accuracy: 0.01)
  }

  // N=3, 0.5 fracs (absolute): each col=500, content overflows.
  // Focused col 1 forces scroll. offset=8, visibleRange=0..<2 (any-part-visible).
  func testLazyFocusAlreadyVisible() {
    let ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 1)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, range) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U)
    XCTAssertEqual(offset, 8, accuracy: 0.5)
    XCTAssertTrue(range.contains(1))
  }

  // N=3, 0.5 fracs (absolute): content overflows, focus col 0.
  // Clamped to offset=0, visibleRange=0..<2 (any-part-visible).
  func testScrollLeftFlush() {
    let ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 0)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, range) = ViewportCalc.resolveOffset(
      anchor: 492, focused: ws.focusedColumnIndex, strip: cols, U: U)
    XCTAssertEqual(offset, 0, accuracy: 0.5)
    XCTAssertTrue(range.contains(0))
  }

  // N=4, all frac=0.7 (absolute): each col=700, content overflows (2824 > 1000).
  // Focused col 3 forces scroll right. offset=1824, visibleRange=2..<4 (any-part-visible).

  func testDegenerateWideColumnRightFlush() {
    let ws = makeWorkspace(fractions: [0.7, 0.7, 0.7, 0.7], focus: 3)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, range) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U)
    XCTAssertEqual(offset, 1824, accuracy: 1.0)
    XCTAssertEqual(range, 2..<4)
    // Focused column's right edge flush with viewport
    XCTAssertEqual(cols[3].right - offset, 1000, accuracy: 1.0)
  }

  // Variable-width columns (absolute): (0.6,0.3,0.3), gap=0.
  // col0=600, col1=300, col2=300; content=1200 > U=1000, so scrolling needed.
  // Focused col 2: offset=200, visibleRange=0..<3 (any-part-visible).
  func testVariableWidthScrollBoundary() {
    let ws = makeWorkspace(fractions: [0.6, 0.3, 0.3], focus: 2)
    let screen = makeScreen()
    let gaps = makeGaps(column: 0)
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, range) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U)
    XCTAssertEqual(offset, 200, accuracy: 1.0)
    XCTAssertTrue(range.contains(2))
    XCTAssertLessThanOrEqual(
      cols[range.upperBound - 1].right - offset, U + 0.01,
      "last visible column right edge must not exceed U")
  }

  // MARK: - Any-part-visible (AABB overlap)

  // Any-part-visible: a column overflowing the viewport right edge by a
  // sub-pixel margin (0.3pt) still overlaps the viewport, so it IS visible.

  func testVisibleWithAnyPart_RightOverflow() {
    let cols = [
      ColumnLayout(left: 0, width: 500),
      ColumnLayout(left: 500, width: 500.3),
    ]
    XCTAssertEqual(ViewportCalc.visibleAtOffset(cols, 0, 1000), 0..<2)
  }

  // Any-part-visible: a column starting before the viewport left edge
  // by a sub-pixel margin (-0.3) still overlaps the viewport, so it IS visible.

  func testVisibleWithAnyPart_LeftOverflow() {
    let cols = [
      ColumnLayout(left: -0.3, width: 500),
      ColumnLayout(left: 500, width: 500),
    ]
    XCTAssertEqual(ViewportCalc.visibleAtOffset(cols, 0, 1000), 0..<2)
  }

  // Float noise within Double epsilon at magnitude 1000 (~1e-13) is admitted.
  // Any-part-visible detection: left=-1e-8, right=1000-1e-8; overlaps viewport. Admitted.

  func testVisibleAdmitsLeftFloatNoise() {
    // left = -1e-8 is within leftEpsilon (0.01), so admitted
    let cols = [ColumnLayout(left: -1e-8, width: 1000)]
    XCTAssertEqual(ViewportCalc.visibleAtOffset(cols, 0, 1000), 0..<1)
  }

  // Any-part-visible: right edge has float noise (1000+1e-8) but column
  // still overlaps viewport, so it IS visible.

  func testVisibleWithAnyPart_RightFloatNoise() {
    let cols = [ColumnLayout(left: 0, width: 1000 + 1e-8)]
    XCTAssertEqual(ViewportCalc.visibleAtOffset(cols, 0, 1000), 0..<1)
  }

  // MARK: - Layout / reflow consistency tests

  // N=3, 0.5 fracs (absolute): each col=500, content overflows viewport.
  // ViewportCalc scrolls to keep focused column visible; visibleRange=1..<3 (any-part-visible).
  // LayoutEngine must never place an on-screen window whose right edge exceeds the usable area.
  func testLayoutNoWindowSpill() {
    let win0 = WindowNode(id: 1, groupKey: WindowNode.GroupKey(value: 1), pid: 1, title: "w0")
    let win1 = WindowNode(id: 2, groupKey: WindowNode.GroupKey(value: 2), pid: 1, title: "w1")
    let win2 = WindowNode(id: 3, groupKey: WindowNode.GroupKey(value: 3), pid: 1, title: "w2")
    let ws = Workspace(
      id: 1,
      columns: [
        Column(windows: [win0], widthFraction: 0.5),
        Column(windows: [win1], widthFraction: 0.5),
        Column(windows: [win2], widthFraction: 0.5),
      ], focusedColumnIndex: 2)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, visibleRange) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U)
    let frames = LayoutEngine.layout(
      workspace: ws, screen: screen, gaps: gaps,
      viewportOffset: offset, visibleRange: visibleRange)
    for (id, frame) in frames {
      guard frame.minX > -99000 else { continue }  // skip off-screen placements
      XCTAssertLessThanOrEqual(
        frame.maxX, screen.visibleFrame.maxX + 0.01,
        "Window \(id) spills right: frame=\(frame)")
    }
  }

  // MARK: - center-focused-column

  // .always centres the focused column. 3x0.5 cols (each 500, gaps 8):
  // col1.left=508, U=1000 -> offset = 508 - (1000-500)/2 = 258.
  func testCenterAlwaysCentersFocusedColumn() {
    let ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 1)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, range) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U, centerMode: .always)
    XCTAssertEqual(offset, 258, accuracy: 1.0)
    XCTAssertTrue(range.contains(1))
    // Focused column is centred: equal left/right margin around it.
    XCTAssertEqual(cols[1].left - offset, U - (cols[1].left - offset) - cols[1].width, accuracy: 1.0)
  }

  // .onOverflow centres only when the focused column is wider than the viewport.
  // Single 1.5-fr column (width 1500 > U 1000) -> offset = 0 - (1000-1500)/2 = 250.
  func testCenterOnOverflowCentersWideColumn() {
    let ws = makeWorkspace(fractions: [1.5], focus: 0)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, _) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U, centerMode: .onOverflow)
    XCTAssertEqual(offset, 250, accuracy: 1.0)
  }

  // .always centres the first column even though that needs a negative offset
  // (col0.left=0, width=500, U=1000 -> offset = 0 - (1000-500)/2 = -250).
  // The [0, maxScroll] clamp must NOT pin edge columns when centering.
  func testCenterAlwaysCentersFirstColumnWithNegativeOffset() {
    let ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 0)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, range) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U, centerMode: .always)
    XCTAssertEqual(offset, -250, accuracy: 1.0)
    XCTAssertTrue(range.contains(0))
    // Focused column centred: left margin == right margin.
    XCTAssertEqual(cols[0].left - offset, U - (cols[0].left - offset) - cols[0].width, accuracy: 1.0)
  }

  // .always centres even when all content fits the viewport (maxScroll ~= 0),
  // where the overflow guard would otherwise early-return offset 0.
  func testCenterAlwaysCentersWhenContentFits() {
    let ws = makeWorkspace(fractions: [0.5], focus: 0)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, range) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U, centerMode: .always)
    XCTAssertEqual(offset, cols[0].left - (U - cols[0].width) / 2, accuracy: 1.0)
    XCTAssertEqual(range, 0..<1)
  }

  // MARK: - always-center-single-column

  // Single column with the flag on is centred even under centerMode .never,
  // bypassing the [0, maxScroll] clamp. 1x0.5 col (width 500, left 0, U 1000):
  // offset = 0 - (1000-500)/2 = -250.
  func testAlwaysCenterSingleColumnCentersLoneColumn() {
    let ws = makeWorkspace(fractions: [0.5], focus: 0)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, range) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U,
      centerMode: .never, alwaysCenterSingleColumn: true)
    XCTAssertEqual(offset, cols[0].left - (U - cols[0].width) / 2, accuracy: 1.0)
    XCTAssertEqual(range, 0..<1)
    // Focused column centred: left margin == right margin.
    XCTAssertEqual(cols[0].left - offset, U - (cols[0].left - offset) - cols[0].width, accuracy: 1.0)
  }

  // With the flag off, a lone column under .never stays flush to the left
  // (offset 0) rather than being centred.
  func testAlwaysCenterSingleColumnOffKeepsFlush() {
    let ws = makeWorkspace(fractions: [0.5], focus: 0)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, _) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U,
      centerMode: .never, alwaysCenterSingleColumn: false)
    XCTAssertEqual(offset, 0, accuracy: 0.5)
  }

  // The flag only applies to a lone column. With multiple columns it must not
  // override .never, which just scrolls the focused column into view.
  func testAlwaysCenterSingleColumnIgnoresMultiColumn() {
    let ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 2)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (withFlag, _) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U,
      centerMode: .never, alwaysCenterSingleColumn: true)
    let (withoutFlag, _) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U,
      centerMode: .never, alwaysCenterSingleColumn: false)
    XCTAssertEqual(withFlag, withoutFlag, accuracy: 0.01)
  }

  // A lone column wider than the viewport is still centred (negative offset),
  // matching .always behaviour. 1x1.5 col (width 1500, U 1000):
  // offset = 0 - (1000-1500)/2 = 250.
  func testAlwaysCenterSingleColumnCentersWideColumn() {
    let ws = makeWorkspace(fractions: [1.5], focus: 0)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, _) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U,
      centerMode: .never, alwaysCenterSingleColumn: true)
    XCTAssertEqual(offset, 250, accuracy: 1.0)
  }

  // .onOverflow falls back to scroll-into-view when the focused column fits.
  func testCenterOnOverflowFallsBackToFit() {
    let ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 1)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (onOverflow, _) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U, centerMode: .onOverflow)
    let (never, _) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U, centerMode: .never)
    XCTAssertEqual(onOverflow, never, accuracy: 0.01)
  }

  // After widening col 0 to 0.7, content overflows more. The saved scroll offset
  // (516) is stale for the new geometry; resolveOffset recomputes to 716,
  // keeping col 2 visible (range=1..<3, any-part-visible) without exceeding maxScroll.
  func testPostWidthChangeReflow() {
    var ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 2)
    let screen = makeScreen()
    let gaps = makeGaps()
    // Establish initial scroll position (content overflows, offset=516)
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (savedOffset, _) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U)
    // Widen col 0; the saved offset is now stale for the new geometry
    ws.columns[0].widthFraction = 0.7
    let newCols = LayoutGeometry.columns(ws, screen, gaps)
    let (reflow, range) = ViewportCalc.resolveOffset(
      anchor: savedOffset, focused: ws.focusedColumnIndex, strip: newCols, U: U)
    XCTAssertTrue(range.contains(2), "focus col must be visible after reflow")
    let contentWidth = LayoutGeometry.contentWidth(newCols)
    let maxScroll = max(0, contentWidth - U)
    XCTAssertGreaterThanOrEqual(reflow, -0.01)
    XCTAssertLessThanOrEqual(reflow, maxScroll + 0.01)
  }
}
