import AppKit

public typealias ScreenID = CGDirectDisplayID
public typealias WorkspaceID = Int

public struct ScreenInfo {
  public let id: ScreenID
  public let frame: NSRect
  public let visibleFrame: NSRect
}

public struct ScreenState {
  public var info: ScreenInfo
  public var workspaces: [WorkspaceID: Workspace]
  public var activeWorkspaceID: WorkspaceID
}

public struct TilerState {
  public var screens: [ScreenID: ScreenState]

  public init(screens: [ScreenID: ScreenState] = [:]) {
    self.screens = screens
  }

  @discardableResult
  mutating func swapWindowID(from oldID: CGWindowID, to newID: CGWindowID, title: String) -> Bool {
    for (screenID, var screenState) in screens {
      for (wsID, var workspace) in screenState.workspaces {
        if workspace.swapBackingID(from: oldID, to: newID, title: title) {
          screenState.workspaces[wsID] = workspace
          screens[screenID] = screenState
          return true
        }
      }
    }
    return false
  }
}
