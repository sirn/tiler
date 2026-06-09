import Foundation
import CoreGraphics

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
public func consumeOrExpel(_ workspace: inout Workspace, direction: HorizontalDirection) -> Bool {
  let focusedColumnIndex = workspace.focusedColumnIndex
  guard workspace.columns.indices.contains(focusedColumnIndex) else { return false }
  var cols = workspace.columns
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
    workspace.columns = cols
    workspace.focusedColumnIndex = insertAt
    return true
  } else {
    let targetIndex = direction == .left ? focusedColumnIndex - 1 : focusedColumnIndex + 1
    guard cols.indices.contains(targetIndex) else { return false }
    cols.remove(at: focusedColumnIndex)
    let adjustedTarget = targetIndex > focusedColumnIndex ? targetIndex - 1 : targetIndex
    cols[adjustedTarget].windows.append(win)
    cols[adjustedTarget].focusedWindowIndex = cols[adjustedTarget].windows.count - 1
    cols[adjustedTarget].measuredMinWidth = nil
    workspace.columns = cols
    workspace.focusedColumnIndex = adjustedTarget
    return true
  }
}

/// Replace a tile's backing CGWindowID in place, preserving its stable `groupKey` and pid
/// (only the id and title change). Returns the updated columns, or nil if no tile has `oldID`.
/// Pure: used by WindowManager.swapWindowID so the identity-preservation invariant is testable.
public func swapBackingID(
  in columns: [Column], from oldID: CGWindowID, to newID: CGWindowID, title: String
) -> [Column]? {
  for (colIdx, column) in columns.enumerated() {
    if let winIdx = column.windows.firstIndex(where: { $0.id == oldID }) {
      var result = columns
      let existing = column.windows[winIdx]
      result[colIdx].windows[winIdx] = WindowNode(
        id: newID, groupKey: existing.groupKey, pid: existing.pid, title: title)
      return result
    }
  }
  return nil
}
