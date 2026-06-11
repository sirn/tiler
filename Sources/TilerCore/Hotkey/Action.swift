import Foundation

public enum Action: Equatable {
  case focusColumnLeft
  case focusColumnRight
  case moveColumnLeft
  case moveColumnRight
  case focusWindowUp
  case focusWindowDown
  case focusScreenPrevious
  case focusScreenNext
  case moveToScreenPrevious
  case moveToScreenNext
  case moveWindowUp
  case moveWindowDown
  case focusWorkspace(Int)
  case moveToWorkspace(Int)
  case increaseColumnWidth
  case decreaseColumnWidth
  case toggleColumnTabbed
  case closeWindow
  case toggleFullscreen
  case consumeOrExpelLeft
  case consumeOrExpelRight
  case dumpFrameState

  /// Parse an action string with optional arguments.
  /// e.g. "focus_workspace" with args ["3"] → .focusWorkspace(3)
  public static func parse(_ name: String, args: [String] = []) -> Action? {
    switch name {
    case "focus_column_left": return .focusColumnLeft
    case "focus_column_right": return .focusColumnRight
    case "move_column_left": return .moveColumnLeft
    case "move_column_right": return .moveColumnRight
    case "focus_window_up": return .focusWindowUp
    case "focus_window_down": return .focusWindowDown
    case "move_window_up": return .moveWindowUp
    case "move_window_down": return .moveWindowDown
    case "focus_workspace":
      if let n = args.first.flatMap(Int.init) { return .focusWorkspace(n) }
      return nil
    case "move_to_workspace":
      if let n = args.first.flatMap(Int.init) { return .moveToWorkspace(n) }
      return nil
    case "increase_column_width": return .increaseColumnWidth
    case "decrease_column_width": return .decreaseColumnWidth
    case "toggle_column_tabbed": return .toggleColumnTabbed
    case "close_window": return .closeWindow
    case "toggle_fullscreen": return .toggleFullscreen
    case "consume_or_expel_left": return .consumeOrExpelLeft
    case "consume_or_expel_right": return .consumeOrExpelRight
    case "focus_screen_previous": return .focusScreenPrevious
    case "focus_screen_next": return .focusScreenNext
    case "move_to_screen_previous": return .moveToScreenPrevious
    case "move_to_screen_next": return .moveToScreenNext
    case "dump_frame_state": return .dumpFrameState
    default: return nil
    }
  }
}
