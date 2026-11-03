import CoreGraphics

struct ReducerEnv {
  var workspaceCount: Int
  var activeScreenID: ScreenID?
  var orderedScreenIDs: [ScreenID]
  var focusColumnWrap: Bool
  var gaps: GapConfig

  init(
    workspaceCount: Int,
    activeScreenID: ScreenID? = nil,
    orderedScreenIDs: [ScreenID] = [],
    focusColumnWrap: Bool = false,
    gaps: GapConfig = GapConfig()
  ) {
    self.workspaceCount = workspaceCount
    self.activeScreenID = activeScreenID
    self.orderedScreenIDs = orderedScreenIDs
    self.focusColumnWrap = focusColumnWrap
    self.gaps = gaps
  }
}
