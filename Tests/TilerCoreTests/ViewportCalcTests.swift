import XCTest
@testable import TilerCore

final class ViewportCalcTests: XCTestCase {

  // N=3, 0.5 fracs (totalWeight=1.5): normalization fits all 3 columns within U.
  // offset=0, visibleRange=0..<3. Last column's right edge equals U.
  func testScrollRightNoSpill() {
    let ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 2)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, range) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U)
    XCTAssertEqual(offset, 0, accuracy: 0.5)
    XCTAssertEqual(range, 0..<3)
    // Last visible column's right edge must not exceed U
    let rightEdge = cols[range.upperBound - 1].right - offset
    XCTAssertEqual(rightEdge, 1000, accuracy: 0.01)
  }

  // N=3, 0.5 fracs (totalWeight=1.5): all 3 columns fit, focus col 1 already visible at offset 0.
  func testLazyFocusAlreadyVisible() {
    let ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 1)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, range) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U)
    XCTAssertEqual(offset, 0, accuracy: 0.5)
    XCTAssertTrue(range.contains(1))
  }

  // N=3, 0.5 fracs (totalWeight=1.5): all 3 columns fit, so any anchor clamps to offset=0.
  // Focus col 0 is visible at offset 0.
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

  // N=4, all frac=0.7 (totalWeight=2.8): normalization fits all 4 columns within U.
  // offset=0, visibleRange=0..<4.
  func testDegenerateWideColumnRightFlush() {
    let ws = makeWorkspace(fractions: [0.7, 0.7, 0.7, 0.7], focus: 3)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, range) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U)
    // With normalization: totalWeight=2.8, each col=244, all 4 fit
    XCTAssertEqual(offset, 0, accuracy: 1.0)
    XCTAssertEqual(range, 0..<4)
    // All columns fit: focused column's right edge equals U
    XCTAssertEqual(cols[3].right - offset, 1000, accuracy: 1.0)
  }

  // Variable-width columns with normalization: (0.6,0.3,0.3), totalWeight=1.2, gap=0.
  // col0=500, col1=250, col2=250; all fit within U=1000, so offset=0.
  func testVariableWidthScrollBoundary() {
    let ws = makeWorkspace(fractions: [0.6, 0.3, 0.3], focus: 2)
    let screen = makeScreen()
    let gaps = makeGaps(column: 0)
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, range) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U)
    XCTAssertEqual(offset, 0, accuracy: 1.0)
    XCTAssertTrue(range.contains(2))
    XCTAssertLessThanOrEqual(
      cols[range.upperBound - 1].right - offset, U + 0.01,
      "last visible column right edge must not exceed U")
  }

  // MARK: - Strict containment edge cases

  // Strict right-edge containment: a column overflowing the viewport by a
  // sub-pixel margin (0.3pt — within the old 0.5 tolerance) must be EXCLUDED.
  func testVisibleExcludesSubPixelRightOverflow() {
    let cols = [
      ColumnLayout(left: 0, width: 500),
      ColumnLayout(left: 500, width: 500.3),
    ]
    XCTAssertEqual(ViewportCalc.visibleAtOffset(cols, 0, 1000), 0..<1)
  }

  // Strict left-edge containment: a column starting before the viewport left
  // by a sub-pixel margin must be EXCLUDED.
  func testVisibleExcludesSubPixelLeftOverflow() {
    let cols = [
      ColumnLayout(left: -0.3, width: 500),
      ColumnLayout(left: 500, width: 500),
    ]
    XCTAssertEqual(ViewportCalc.visibleAtOffset(cols, 0, 1000), 1..<2)
  }

  // Float noise within Double epsilon at magnitude 1000 (~1e-13) is admitted.
  // Float noise on LEFT edge is admitted (via leftEpsilon).
  // Right edge uses STRICT containment - NO epsilon for overflow.
  func testVisibleAdmitsLeftFloatNoise() {
    // left = -1e-8 is within leftEpsilon (0.01), so admitted
    let cols = [ColumnLayout(left: -1e-8, width: 1000)]
    XCTAssertEqual(ViewportCalc.visibleAtOffset(cols, 0, 1000), 0..<1)
  }

  func testVisibleRejectsRightFloatNoise() {
    // Right edge = 1000 + 1e-8 > 1000 (U), so REJECTED (strict containment)
    let cols = [ColumnLayout(left: 0, width: 1000 + 1e-8)]
    XCTAssertEqual(ViewportCalc.visibleAtOffset(cols, 0, 1000), 0..<0)
  }

  // MARK: - Layout / reflow consistency tests

  // End-to-end: ViewportCalc + LayoutEngine must never place an on-screen window
  // whose right edge exceeds the usable area (no spill regardless of which column
  // is focused or what the starting offset is).
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

  // After increasing col 0's width to 0.7, totalWeight=1.7; normalization refits
  // all columns within ~U. The saved scroll offset is stale but resolveOffset
  // recomputes and keeps col 2 visible without exceeding maxScroll.
  func testPostWidthChangeReflow() {
    var ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 2)
    let screen = makeScreen()
    let gaps = makeGaps()
    // Establish initial scroll position (all cols fit, offset=0)
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
