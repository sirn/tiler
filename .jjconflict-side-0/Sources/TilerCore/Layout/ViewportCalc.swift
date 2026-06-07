import AppKit
import Foundation

public enum ViewportCalc {
  // Tolerance for float-representation error ONLY on left edge.
  // Right edge uses STRICT containment to prevent window overflow.
  // Column geometry is integer-aligned (widths rounded in LayoutGeometry).
  // Viewport offset is rounded to integer in LayoutEngine.
  // U (usable width) may be non-integer; strict right check prevents spill.
  private static let leftEpsilon: CGFloat = 0.01

  /// Resolve viewport offset by scrolling the focused column fully into view.
  /// The anchor (persisted scrollOffset) is clamped, then corrected so that:
  ///   focused.left >= offset && focused.right <= offset + U
  /// Clamped to [0, maxScroll]. Offset is rounded to integer for pixel alignment.
  ///
  /// - Returns: (offset, visibleRange) where visibleRange contains ONLY columns that fully fit.
  static func resolveOffset(
    anchor: CGFloat, focused: Int, strip: [ColumnLayout], U: CGFloat
  ) -> (offset: CGFloat, visibleRange: Range<Int>) {
    guard !strip.isEmpty else { return (0, 0..<0) }
    let f = min(focused, strip.count - 1)
    let maxScroll = max(0, LayoutGeometry.contentWidth(strip) - U)
    guard maxScroll > leftEpsilon else { return (0, 0..<strip.count) }
    var s = min(max(anchor, 0), maxScroll)
    if strip[f].left < s { s = strip[f].left }
    if strip[f].right > s + U { s = strip[f].right - U }
    // Round to integer for pixel-perfect alignment with LayoutEngine
    let offset = round(clampToEdge(min(max(s, 0), maxScroll), maxScroll))
    let visible = visibleAtOffset(strip, offset, U)
    return (offset, visible)
  }

  /// Full-containment visible check at given offset.
  /// Left edge: allows tiny epsilon for float noise on anchor.
  /// Right edge: STRICT containment (no epsilon) to guarantee no window spill.
  static func visibleAtOffset(_ cols: [ColumnLayout], _ s: CGFloat, _ U: CGFloat) -> Range<Int> {
    let viewportRight = s + U
    var lo = cols.count
    var hi = -1
    for i in cols.indices {
      let leftOK = cols[i].left >= s - leftEpsilon
      let rightOK = cols[i].right <= viewportRight  // STRICT: no epsilon
      if leftOK && rightOK {
        if i < lo { lo = i }
        hi = i
      }
    }
    return hi >= lo ? lo..<(hi + 1) : 0..<0
  }

  private static func clampToEdge(_ offset: CGFloat, _ maxScroll: CGFloat) -> CGFloat {
    if offset <= leftEpsilon { return 0 }
    if offset >= maxScroll - leftEpsilon { return maxScroll }
    return offset
  }
}
