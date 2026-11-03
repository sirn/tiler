import XCTest

@testable import TilerCore

final class LayoutGeometryTests: XCTestCase {

  // Single column: fraction=0.3 → 300 requested (absolute), but minWidth=400 clamps
  func testMinWidthSingleColumnAbsorbed() {
    let screen = makeScreen(width: 1000)
    let gaps = makeGaps(column: 0)
    let ws = makeWorkspaceWithMinWidths(fractions: [0.3], minWidths: [400], focus: 0)
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    XCTAssertEqual(cols[0].width, 400, accuracy: 1.0)
  }

  // Two columns: col0 has large measuredMinWidth; col1 must start after col0.right + gap
  func testMinWidthTwoColumnsNoOverlap() {
    let screen = makeScreen(width: 1000)
    let gaps = makeGaps(column: 8)
    // col0: fraction=0.3 → 300 requested (absolute), but minWidth=500 overrides
    // col1: fraction=0.3 → 300
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

  // Baseline: a proportion is a share of the slot width (U + gap = 1008), minus one
  // gap per column. 3 columns of 0.5 each: 496 wide, lefts 0/504/1008, overflow
  func testMinWidthNilBaselineSharesGapSpace() {
    let screen = makeScreen(width: 1000)
    let gaps = makeGaps(column: 8)
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

  // Fractions that add up to 1 fill the usable width exactly, with no overshoot.
  func testFractionsSummingToOneFillUsableWidth() {
    let screen = makeScreen(width: 1000)
    let gaps = makeGaps(column: 8)
    let ws = makeWorkspace(fractions: [0.5, 0.5], focus: 0)
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    XCTAssertEqual(
      LayoutGeometry.contentWidth(cols), LayoutGeometry.usableWidth(screen, gaps), accuracy: 0.01)
  }

  // A fixed width is absolute: the column keeps it whatever the viewport is, and the
  // proportion column after it starts after the fixed column and one gap.
  func testFixedWidthColumnKeepsItsWidth() {
    let screen = makeScreen(width: 1000)
    let gaps = makeGaps(column: 8)
    let ws = Workspace(
      id: 1,
      columns: [Column(width: .fixed(300)), Column(width: .proportion(0.5))],
      focusedColumnIndex: 0)
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    XCTAssertEqual(cols[0].width, 300, accuracy: 0.01)
    XCTAssertEqual(cols[1].left, 308, accuracy: 0.01)
    XCTAssertEqual(cols[1].width, 496, accuracy: 1.0)
  }

  // A window's width converted to a proportion resolves back to the same width.
  func testProportionForWidthResolvesToSameWidth() {
    let screen = makeScreen(width: 1000)
    let gaps = makeGaps(column: 8)
    let proportion = LayoutGeometry.proportion(forWidth: 700, screen, gaps)
    XCTAssertNotNil(proportion)
    let ws = Workspace(
      id: 1, columns: [Column(width: .proportion(proportion ?? 0))], focusedColumnIndex: 0)
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    XCTAssertEqual(cols[0].width, 700, accuracy: 1.0)
  }

  // Outer gaps, column gaps and column widths add up to the full screen width.
  func testGapsAndWidthsSumToScreenWidth() {
    let screen = makeScreen(width: 1000)
    let gaps = GapConfig(outerGaps: 8, innerGaps: 6, columnGaps: 8)
    let ws = makeWorkspace(fractions: [0.5, 0.5], focus: 0)
    let cols = LayoutGeometry.columns(ws, screen, gaps)
    let total = 2 * gaps.outerGaps + cols.reduce(0) { $0 + $1.width } + gaps.columnGaps
    XCTAssertEqual(total, screen.visibleFrame.width, accuracy: 0.01)
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
}
