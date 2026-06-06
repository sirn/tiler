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

  private func makeWorkspaceWithMinWidths(fractions: [CGFloat], minWidths: [CGFloat?], focus: Int)
    -> Workspace
  {
    let cols = zip(fractions, minWidths).map { (frac, minW) in
      Column(widthFraction: frac, measuredMinWidth: minW)
    }
    return Workspace(id: 1, columns: cols, focusedColumnIndex: focus)
  }

  // MARK: - measuredMinWidth / LayoutGeometry tests

  // Single column: measuredMinWidth larger than computed width should win
  func testMinWidthSingleColumnAbsorbed() {
    let screen = makeScreen(width: 1000)
    let gaps = makeGaps(column: 0)
    // widthFraction=0.3 → requested=300, but measuredMinWidth=400 should override
    let ws = makeWorkspaceWithMinWidths(fractions: [0.3], minWidths: [400], focus: 0)
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    XCTAssertEqual(cols[0].width, 400, accuracy: 1.0)
  }

  // Two columns: col0 has large measuredMinWidth; col1 must start after col0.right + gap
  func testMinWidthTwoColumnsNoOverlap() {
    let screen = makeScreen(width: 1000)
    let gaps = makeGaps(column: 8)
    // col0: fraction=0.3 → ~300 requested, but minWidth=500 overrides
    // col1: fraction=0.3 → ~300
    let ws = makeWorkspaceWithMinWidths(fractions: [0.3, 0.3], minWidths: [500, nil], focus: 0)
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    XCTAssertEqual(cols[1].left, cols[0].right + 8, accuracy: 1.0)
  }

  // Absorbed total exceeds U: ViewportCalc.resolveOffset returns maxScroll > 0
  // and focused column right edge is within the viewport
  func testMinWidthExceedsViewportScrollable() {
    let screen = makeScreen(width: 1000)
    let gaps = makeGaps(column: 0)
    // col0: fraction=0.5 but minWidth=700; col1: fraction=0.5 but minWidth=700
    // total content = 1400 > U=1000 → maxScroll=400
    let ws = makeWorkspaceWithMinWidths(fractions: [0.5, 0.5], minWidths: [700, 700], focus: 1)
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, _) = ViewportCalc.resolveOffset(anchor: 0, focused: 1, strip: cols, U: U)
    let maxScroll = max(0, LayoutGeometry.contentWidth(cols) - U)
    XCTAssertGreaterThan(maxScroll, 0, "content must overflow when min-widths exceed U")
    // Focused column right edge must fit within viewport
    XCTAssertLessThanOrEqual(cols[1].right - offset, U + 0.01)
  }

  // Baseline: with measuredMinWidth == nil, columns output matches hardcoded expectation
  func testMinWidthNilBaselineUnchanged() {
    let screen = makeScreen(width: 1000)
    let gaps = makeGaps(column: 8)
    // 3 columns of 0.5 each: widthBase = 1000 - 8 = 992; each col = round(992*0.5) = 496
    let ws = makeWorkspaceWithMinWidths(
      fractions: [0.5, 0.5, 0.5], minWidths: [nil, nil, nil], focus: 0)
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    XCTAssertEqual(cols[0].width, 496, accuracy: 1.0)
    XCTAssertEqual(cols[1].width, 496, accuracy: 1.0)
    XCTAssertEqual(cols[2].width, 496, accuracy: 1.0)
    XCTAssertEqual(cols[0].left, 0, accuracy: 0.01)
    XCTAssertEqual(cols[1].left, 504, accuracy: 1.0)  // 496 + 8
    XCTAssertEqual(cols[2].left, 1008, accuracy: 1.0)  // 496 + 8 + 496 + 8
  }

  // Adjacent-pair no-overlap: cols[i].right + columnGaps <= cols[i+1].left for all i
  func testMinWidthAdjacentPairsNoOverlap() {
    let screen = makeScreen(width: 1000)
    let gaps = makeGaps(column: 8)
    let configs: [([CGFloat], [CGFloat?])] = [
      ([0.3, 0.3, 0.3], [400, nil, nil]),
      ([0.5, 0.5, 0.5], [nil, 600, nil]),
      ([0.4, 0.4, 0.4], [300, 300, 300]),
    ]
    for (fracs, minWs) in configs {
      let ws = makeWorkspaceWithMinWidths(fractions: fracs, minWidths: minWs, focus: 0)
      let cols = LayoutGeometry.columns(ws, screen, gaps)
      for i in 0..<(cols.count - 1) {
        XCTAssertLessThanOrEqual(
          cols[i].right + gaps.columnGaps, cols[i + 1].left + 0.01,
          "cols[\(i)].right + gap > cols[\(i+1)].left in config \(fracs) minWs \(minWs)")
      }
    }
  }

  // MARK: - ViewportCalc tests

  // N=3, 0.5 fracs, focus col 2, starting from offset 0:
  // right-flush brings col 2's right edge to U; visibleRange is derived from
  // the final offset (not a pre-clamp page start).
  func testScrollRightNoSpill() {
    let ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 2)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, range) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U)
    XCTAssertEqual(offset, 504, accuracy: 0.5)
    XCTAssertEqual(range, 1..<3)
    // Last visible column's right edge must not exceed U
    let rightEdge = cols[range.upperBound - 1].right - offset
    XCTAssertEqual(rightEdge, 1000, accuracy: 0.01)
  }

  // N=3, 0.5 fracs, focus col 1, already visible at offset 0 -> lazy, no scroll.
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

  // N=3, 0.5 fracs, focus col 0, current offset 492 (rightmost scroll):
  // focus is left of vis={1,2} -> left-flush -> offset=0, col 0 visible.
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

  // N=4, all frac=0.7: no two columns fit together.
  // Focus col 3 (last) from offset 0 -> right-flush: col 3's right edge flushes to U.
  func testDegenerateWideColumnRightFlush() {
    let ws = makeWorkspace(fractions: [0.7, 0.7, 0.7, 0.7], focus: 3)
    let screen = makeScreen()
    let gaps = makeGaps()
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let U = LayoutGeometry.usableWidth(screen, gaps)
    let (offset, range) = ViewportCalc.resolveOffset(
      anchor: 0, focused: ws.focusedColumnIndex, strip: cols, U: U)
    // With U=1000, widthBase=992, w=694: col3.right=2800, offset=1800
    XCTAssertEqual(offset, 1800, accuracy: 1.0)
    // Only focused column fits (0.7 frac = ~683 > half of U)
    XCTAssertEqual(range, 3..<4)
    // Right-flush: focused column's right edge must equal U within tolerance
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

  // MARK: - classifyGeometryChange tests

  func testEchoExactMatch() {
    let rect = NSRect(x: 10, y: 20, width: 300, height: 200)
    XCTAssertEqual(classifyGeometryChange(observed: rect, applied: rect, tolerance: 2.0), .echo)
  }

  func testEchoWithinTolerance() {
    let applied = NSRect(x: 10, y: 20, width: 300, height: 200)
    let observed = NSRect(x: 10 + 1.9, y: 20, width: 300, height: 200)
    XCTAssertEqual(
      classifyGeometryChange(observed: observed, applied: applied, tolerance: 2.0), .echo)
  }

  func testEchoAtToleranceBoundaryIsGenuine() {
    let applied = NSRect(x: 10, y: 20, width: 300, height: 200)
    let observed = NSRect(x: 10 + 2.0, y: 20, width: 300, height: 200)
    XCTAssertEqual(
      classifyGeometryChange(observed: observed, applied: applied, tolerance: 2.0), .genuineMove)
  }

  func testGenuineMoveBeyondTolerance() {
    let applied = NSRect(x: 10, y: 20, width: 300, height: 200)
    let observed = NSRect(x: 10 + 3.0, y: 20, width: 300, height: 200)
    XCTAssertEqual(
      classifyGeometryChange(observed: observed, applied: applied, tolerance: 2.0), .genuineMove)
  }

  func testNoRecordIsGenuineMove() {
    let rect = NSRect(x: 10, y: 20, width: 300, height: 200)
    XCTAssertEqual(classifyGeometryChange(observed: rect, applied: nil, tolerance: 2.0), .genuineMove)
  }

  // MARK: - reconcilePlan tests

  func testAddNewWindow() {
    let plan = reconcilePlan(
      managedIDs: [1], stillAliveIDs: [1], tileableIDs: [1, 2],
      missingCounts: [:], missThreshold: 2)
    XCTAssertEqual(plan.toAdd, [2])
    XCTAssertEqual(plan.toReap, [])
  }

  func testReapAfterTwoMisses() {
    let plan = reconcilePlan(
      managedIDs: [1], stillAliveIDs: [], tileableIDs: [],
      missingCounts: [1: 1], missThreshold: 2)
    XCTAssertEqual(plan.toReap, [1])
    XCTAssertEqual(plan.updatedMissingCounts[1], 2)
  }

  func testTransientMissNotReaped() {
    let plan = reconcilePlan(
      managedIDs: [1], stillAliveIDs: [], tileableIDs: [],
      missingCounts: [:], missThreshold: 2)
    XCTAssertEqual(plan.toReap, [])
    XCTAssertEqual(plan.updatedMissingCounts[1], 1)
    XCTAssertTrue(plan.hasPendingMiss)
  }

  func testReappearResetsMissCount() {
    let plan = reconcilePlan(
      managedIDs: [1], stillAliveIDs: [1], tileableIDs: [1],
      missingCounts: [1: 1], missThreshold: 2)
    XCTAssertEqual(plan.updatedMissingCounts[1], 0)
    XCTAssertEqual(plan.toReap, [])
    XCTAssertFalse(plan.hasPendingMiss)
  }

  func testOffscreenParkedNotReapedIfStillTileable() {
    let plan = reconcilePlan(
      managedIDs: [1], stillAliveIDs: [1], tileableIDs: [],
      missingCounts: [:], missThreshold: 2)
    XCTAssertEqual(plan.toReap, [])
    XCTAssertEqual(plan.toAdd, [])
  }

  func testMissingCountsPrunedForRemovedIds() {
    let plan = reconcilePlan(
      managedIDs: [], stillAliveIDs: [], tileableIDs: [],
      missingCounts: [9: 1], missThreshold: 2)
    XCTAssertNil(plan.updatedMissingCounts[9])
  }

  // MARK: - consumeOrExpel tests

  func testConsumeLoneIntoLeft() {
    let w1 = WindowNode(id: 1, pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, pid: 1, title: "w2")
    let cols = [
      Column(windows: [w1], focusedWindowIndex: 0),
      Column(windows: [w2], focusedWindowIndex: 0),
    ]
    let result = consumeOrExpel(columns: cols, focusedColumnIndex: 1, direction: .left)
    XCTAssertNotNil(result)
    XCTAssertEqual(result!.columns.count, 1)
    XCTAssertEqual(result!.columns[0].windows, [w1, w2])
    XCTAssertEqual(result!.focusedColumnIndex, 0)
    XCTAssertEqual(result!.columns[0].focusedWindowIndex, 1)
  }

  func testExpelStackedToRight() {
    let w1 = WindowNode(id: 1, pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, pid: 1, title: "w2")
    let cols = [Column(windows: [w1, w2], focusedWindowIndex: 1)]
    let result = consumeOrExpel(columns: cols, focusedColumnIndex: 0, direction: .right)
    XCTAssertNotNil(result)
    XCTAssertEqual(result!.columns.count, 2)
    XCTAssertEqual(result!.columns[0].windows, [w1])
    XCTAssertEqual(result!.columns[1].windows, [w2])
    XCTAssertEqual(result!.focusedColumnIndex, 1)
  }

  func testExpelStackedToLeft() {
    let w1 = WindowNode(id: 1, pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, pid: 1, title: "w2")
    let cols = [Column(windows: [w1, w2], focusedWindowIndex: 1)]
    let result = consumeOrExpel(columns: cols, focusedColumnIndex: 0, direction: .left)
    XCTAssertNotNil(result)
    XCTAssertEqual(result!.columns.count, 2)
    XCTAssertEqual(result!.columns[0].windows, [w2])
    XCTAssertEqual(result!.columns[1].windows, [w1])
    XCTAssertEqual(result!.focusedColumnIndex, 0)
  }

  func testConsumeNoLeftNeighborIsNoop() {
    let w1 = WindowNode(id: 1, pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, pid: 1, title: "w2")
    let cols = [
      Column(windows: [w1], focusedWindowIndex: 0),
      Column(windows: [w2], focusedWindowIndex: 0),
    ]
    let result = consumeOrExpel(columns: cols, focusedColumnIndex: 0, direction: .left)
    XCTAssertNil(result)
  }

  func testConsumeNoRightNeighborIsNoop() {
    let w1 = WindowNode(id: 1, pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, pid: 1, title: "w2")
    let cols = [
      Column(windows: [w1], focusedWindowIndex: 0),
      Column(windows: [w2], focusedWindowIndex: 0),
    ]
    let result = consumeOrExpel(columns: cols, focusedColumnIndex: 1, direction: .right)
    XCTAssertNil(result)
  }

  func testRoundTripConsumeThenExpel() {
    let w1 = WindowNode(id: 1, pid: 1, title: "w1")
    let w2 = WindowNode(id: 2, pid: 1, title: "w2")
    let initial = [
      Column(windows: [w1], focusedWindowIndex: 0),
      Column(windows: [w2], focusedWindowIndex: 0),
    ]
    // Consume col1 into left neighbor → [[w1, w2]], focusedColumnIndex 0
    let consumed = consumeOrExpel(columns: initial, focusedColumnIndex: 1, direction: .left)
    XCTAssertNotNil(consumed)
    // Expel w2 back to the right → [[w1], [w2]], focusedColumnIndex 1
    let expelled = consumeOrExpel(
      columns: consumed!.columns,
      focusedColumnIndex: consumed!.focusedColumnIndex,
      direction: .right)
    XCTAssertNotNil(expelled)
    XCTAssertEqual(expelled!.columns.count, 2)
    XCTAssertEqual(expelled!.columns[0].windows, [w1])
    XCTAssertEqual(expelled!.columns[1].windows, [w2])
    XCTAssertEqual(expelled!.focusedColumnIndex, 1)
  }

  // MARK: - Variable-width boundary and reflow tests

  // Variable-width columns: focused col cannot left-flush past maxScroll.
  // col0=600, col1=300, col2=300 (columnGaps=0). W=1200, U=1000, maxScroll=200.
  // Focus=2 from offset 0 -> rightward -> packFromLeft clamps at maxScroll=200.
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

  // After increasing col 0's width, the saved scrollOffset (492) is passed as
  // currentOffset. The old visible range no longer contains focus, so resolveOffset
  // must recompute and keep col 2 visible without exceeding maxScroll.
  func testPostWidthChangeReflow() {
    var ws = makeWorkspace(fractions: [0.5, 0.5, 0.5], focus: 2)
    let screen = makeScreen()
    let gaps = makeGaps()
    // Establish initial scroll position (right-flush col 2)
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
