import AppKit

public typealias ScreenID = CGDirectDisplayID
public typealias WorkspaceID = Int

public struct ScreenInfo {
    public let id: ScreenID
    public let frame: NSRect
    public let visibleFrame: NSRect
}

public struct TilerState {
    public var screens: [ScreenID: ScreenInfo]
    public var workspaces: [WorkspaceID: Workspace]
    public var screenWorkspace: [ScreenID: WorkspaceID]
    
    public init(screens: [ScreenID: ScreenInfo] = [:],
                workspaces: [WorkspaceID: Workspace] = [:],
                screenWorkspace: [ScreenID: WorkspaceID] = [:]) {
        self.screens = screens
        self.workspaces = workspaces
        self.screenWorkspace = screenWorkspace
    }
}
