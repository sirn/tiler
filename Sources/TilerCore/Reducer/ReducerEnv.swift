import CoreGraphics

struct ReducerEnv {
  var workspaceCount: Int
  var activeScreenID: ScreenID?
  var orderedScreenIDs: [ScreenID]

  init(
    workspaceCount: Int,
    activeScreenID: ScreenID? = nil,
    orderedScreenIDs: [ScreenID] = []
  ) {
    self.workspaceCount = workspaceCount
    self.activeScreenID = activeScreenID
    self.orderedScreenIDs = orderedScreenIDs
  }
}
