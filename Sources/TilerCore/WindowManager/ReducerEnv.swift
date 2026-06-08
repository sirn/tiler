import CoreGraphics

struct ReducerEnv {
  var workspaceCount: Int
  var defaultColumnWidth: CGFloat
  var activeScreenID: ScreenID?

  init(
    workspaceCount: Int,
    defaultColumnWidth: CGFloat,
    activeScreenID: ScreenID? = nil
  ) {
    self.workspaceCount = workspaceCount
    self.defaultColumnWidth = defaultColumnWidth
    self.activeScreenID = activeScreenID
  }
}
