import CoreGraphics
import Foundation

enum Effect: Equatable {
  case retile
  case focusFocusedWindow(ScreenID, WorkspaceID)
  case closeWindow(CGWindowID, pid_t)
  case toggleFullscreen(CGWindowID, pid_t)
  case refreshTabs(ScreenID, WorkspaceID)
  case scheduleDeferredTabRefresh(ScreenID, WorkspaceID)
  case log(String)
}
