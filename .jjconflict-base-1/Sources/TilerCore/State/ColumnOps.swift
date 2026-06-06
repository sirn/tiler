import Foundation

public enum HorizontalDirection {
  case left
  case right
}

public struct ConsumeOrExpelResult: Equatable {
  public let columns: [Column]
  public let focusedColumnIndex: Int
}

/// niri-style consume-or-expel of the focused window in `direction`.
/// - Stacked column (>1 window): EXPEL the focused window into its own new column on that side.
/// - Lone window: CONSUME it into the neighboring column on that side (append to its stack),
///   removing the emptied source column.
/// Returns nil for a no-op (empty/invalid, or consume with no neighbor on that side).
public func consumeOrExpel(
  columns: [Column], focusedColumnIndex: Int, direction: HorizontalDirection
) -> ConsumeOrExpelResult? {
  guard columns.indices.contains(focusedColumnIndex) else { return nil }
  var cols = columns
  let col = cols[focusedColumnIndex]
  guard col.windows.indices.contains(col.focusedWindowIndex) else { return nil }
  let winIdx = col.focusedWindowIndex
  let win = col.windows[winIdx]

  if col.windows.count > 1 {
    cols[focusedColumnIndex].windows.remove(at: winIdx)
    cols[focusedColumnIndex].measuredMinWidth = nil
    if cols[focusedColumnIndex].focusedWindowIndex >= cols[focusedColumnIndex].windows.count {
      cols[focusedColumnIndex].focusedWindowIndex = cols[focusedColumnIndex].windows.count - 1
    }
    let newCol = Column(
      windows: [win], focusedWindowIndex: 0, mode: col.mode, widthFraction: col.widthFraction)
    let insertAt = direction == .left ? focusedColumnIndex : focusedColumnIndex + 1
    cols.insert(newCol, at: insertAt)
    return ConsumeOrExpelResult(columns: cols, focusedColumnIndex: insertAt)
  } else {
    let targetIndex = direction == .left ? focusedColumnIndex - 1 : focusedColumnIndex + 1
    guard cols.indices.contains(targetIndex) else { return nil }
    cols.remove(at: focusedColumnIndex)
    let adjustedTarget = targetIndex > focusedColumnIndex ? targetIndex - 1 : targetIndex
    cols[adjustedTarget].windows.append(win)
    cols[adjustedTarget].focusedWindowIndex = cols[adjustedTarget].windows.count - 1
    cols[adjustedTarget].measuredMinWidth = nil
    return ConsumeOrExpelResult(columns: cols, focusedColumnIndex: adjustedTarget)
  }
}
