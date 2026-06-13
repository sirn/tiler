import CoreGraphics
import Foundation

enum Effect: Equatable {
  case retile
  case focusFocusedWindow(ScreenID, WorkspaceID)
  case raiseTabbedWindows(ScreenID, WorkspaceID)
  case closeWindow(CGWindowID)
  case toggleFullscreen(CGWindowID)
  case refreshTabs(ScreenID, WorkspaceID)
  case scheduleDeferredTabRefresh(ScreenID, WorkspaceID)
  case log(String)
}