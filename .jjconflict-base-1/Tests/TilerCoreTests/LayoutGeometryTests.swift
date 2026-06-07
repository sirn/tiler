import XCTest
@testable import TilerCore

final class LayoutGeometryTests: XCTestCase {

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
}
