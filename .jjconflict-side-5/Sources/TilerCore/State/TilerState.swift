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
}
