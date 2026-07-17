import CoreGraphics

struct ReducerEnv {
  var workspaceCount: Int
  var activeScreenID: ScreenID?
  var orderedScreenIDs: [ScreenID]
  var focusColumnWrap: Bool

  init(
    workspaceCount: Int,
    activeScreenID: ScreenID? = nil,
    orderedScreenIDs: [ScreenID] = [],
    focusColumnWrap: Bool = false
  ) {
    self.workspaceCount = workspaceCount
    self.activeScreenID = activeScreenID
    self.orderedScreenIDs = orderedScreenIDs
    self.focusColumnWrap = focusColumnWrap
  }
}
