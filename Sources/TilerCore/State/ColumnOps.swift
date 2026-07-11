import Foundation
import CoreGraphics

extension Workspace {

  public enum HorizontalDirection {
    case left
    case right
  }

  /// niri-style consume-or-expel of the focused window in `direction`.
  /// - Stacked column (>1 window): EXPEL the focused window into its own new column on that side.
  /// - Lone window: CONSUME it into the neighboring column on that side (append to its stack),
  ///   removing the emptied source column.
  /// Returns false for a no-op (empty/invalid, or consume with no neighbor on that side).
  @discardableResult
  public mutating func consumeOrExpel(direction: HorizontalDirection) -> Bool {
    let focusedColumnIndex = self.focusedColumnIndex
    guard columns.indices.contains(focusedColumnIndex) else { return false }
    var cols = columns
    let col = cols[focusedColumnIndex]
    guard col.windows.indices.contains(col.focusedWindowIndex) else { return false }
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
      columns = cols
      self.focusedColumnIndex = insertAt
      return true
    } else {
      let targetIndex = direction == .left ? focusedColumnIndex - 1 : focusedColumnIndex + 1
      guard cols.indices.contains(targetIndex) else { return false }
      cols.remove(at: focusedColumnIndex)
      let adjustedTarget = targetIndex > focusedColumnIndex ? targetIndex - 1 : targetIndex
      cols[adjustedTarget].windows.append(win)
      cols[adjustedTarget].focusedWindowIndex = cols[adjustedTarget].windows.count - 1
      cols[adjustedTarget].measuredMinWidth = nil
      columns = cols
      self.focusedColumnIndex = adjustedTarget
      return true
    }
  }

  /// Replace a tile's backing CGWindowID in place, preserving its stable `groupKey` and pid.
  /// Returns true if a tile with `oldID` was found and updated.
  @discardableResult
  public mutating func swapBackingID(
    from oldID: CGWindowID, to newID: CGWindowID, title: String
  ) -> Bool {
    for (colIdx, column) in columns.enumerated() {
      if let winIdx = column.windows.firstIndex(where: { $0.id == oldID }) {
        let existing = columns[colIdx].windows[winIdx]
        columns[colIdx].windows[winIdx] = WindowNode(
          id: newID, groupKey: existing.groupKey, pid: existing.pid, title: title)
        return true
      }
    }
    return false
  }
}
