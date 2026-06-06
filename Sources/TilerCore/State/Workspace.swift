import Foundation

public struct Workspace: Equatable {
  public var id: WorkspaceID
  public var columns: [Column]
  public var focusedColumnIndex: Int
  public var scrollOffset: CGFloat = 0

  public init(
    id: WorkspaceID, columns: [Column] = [], focusedColumnIndex: Int = 0, scrollOffset: CGFloat = 0
  ) {
    self.id = id
    self.columns = columns
    self.focusedColumnIndex = focusedColumnIndex
    self.scrollOffset = scrollOffset
  }
}
