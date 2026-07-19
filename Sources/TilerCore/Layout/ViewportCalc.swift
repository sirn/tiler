import AppKit
import Foundation

public enum ViewportCalc {
  // Tolerance for float-representation error on scroll-edge snapping and overflow guard.
  // Column visibility now uses any-part-visible (AABB overlap) detection.
  private static let leftEpsilon: CGFloat = 0.01

  /// Resolve viewport offset by scrolling the focused column fully into view.
  /// The anchor (persisted scrollOffset) is clamped, then corrected so that:
  ///   focused.left >= offset && focused.right <= offset + U
  /// Clamped to [0, maxScroll] for .never/.onOverflow. .always centres the focused
  /// column and may offset outside [0, maxScroll] (blank space at the strip edges,
  /// Niri parity). Offset is rounded to integer for pixel alignment.
  ///
  /// - Returns: (offset, visibleRange) where visibleRange contains columns with any part overlapping the viewport.
  static func resolveOffset(
    anchor: CGFloat, focused: Int, strip: [ColumnLayout], U: CGFloat,
    centerMode: CenterFocusedColumn = .never,
    alwaysCenterSingleColumn: Bool = false
  ) -> (offset: CGFloat, visibleRange: Range<Int>) {
    guard !strip.isEmpty else { return (0, 0..<0) }
    let f = min(focused, strip.count - 1)
    let maxScroll = max(0, LayoutGeometry.contentWidth(strip) - U)

    // Centring bypasses the overflow guard and the [0, maxScroll] clamp the
    // other modes use to keep content flush, because it may leave blank space
    // at the strip edges (Niri parity). This covers .always, plus the
    // always-center-single-column flag which forces centring of a lone
    // column regardless of center-focused-column.
    let centerSingle = alwaysCenterSingleColumn && strip.count == 1
    if centerMode == .always || centerSingle {
      let s = strip[f].left - (U - strip[f].width) / 2
      let offset = round(s)
      return (offset, visibleAtOffset(strip, offset, U))
    }

    guard maxScroll > leftEpsilon else { return (0, 0..<strip.count) }
    var s = min(max(anchor, 0), maxScroll)
    switch centerMode {
    case .always:
      break
    case .onOverflow:
      // Centre only when the focused column itself doesn't fit the viewport;
      // otherwise scroll it fully into view.
      if strip[f].width > U - leftEpsilon {
        s = strip[f].left - (U - strip[f].width) / 2
      } else {
        if strip[f].left < s { s = strip[f].left }
        if strip[f].right > s + U { s = strip[f].right - U }
      }
    case .never:
      if strip[f].left < s { s = strip[f].left }
      if strip[f].right > s + U { s = strip[f].right - U }
    }
    // Round to integer for pixel-perfect alignment with LayoutEngine
    let offset = round(clampToEdge(min(max(s, 0), maxScroll), maxScroll))
    let visible = visibleAtOffset(strip, offset, U)
    return (offset, visible)
  }

  /// A column is visible if any part of it overlaps the viewport.
  /// This matches the scrolling-WM expectation: a column peeking in by
  /// even 1px on either edge is shown.
  static func visibleAtOffset(_ cols: [ColumnLayout], _ s: CGFloat, _ U: CGFloat) -> Range<Int> {
    let viewportRight = s + U
    var lo = cols.count
    var hi = -1
    for i in cols.indices {
      if cols[i].left < viewportRight && cols[i].right > s {
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
