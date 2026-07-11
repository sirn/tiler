import CoreGraphics

struct ReducerEnv {
  var workspaceCount: Int
  var defaultColumnWidth: CGFloat
  var activeScreenID: ScreenID?
  var orderedScreenIDs: [ScreenID]

  init(
    workspaceCount: Int,
    defaultColumnWidth: CGFloat,
    activeScreenID: ScreenID? = nil,
    orderedScreenIDs: [ScreenID] = []
  ) {
    self.workspaceCount = workspaceCount
    self.defaultColumnWidth = defaultColumnWidth
    self.activeScreenID = activeScreenID
    self.orderedScreenIDs = orderedScreenIDs
  }
}
