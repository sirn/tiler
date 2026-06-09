import Foundation

extension TilerState {
  mutating func withActiveScreen(
    env: ReducerEnv,
    _ body: (ScreenID, inout ScreenState) -> [Effect]
  ) -> [Effect] {
    guard let screenID = env.activeScreenID,
          var screenState = screens[screenID] else { return [] }
    let effects = body(screenID, &screenState)
    screens[screenID] = screenState
    return effects
  }
  mutating func withScreen(
    _ screenID: ScreenID,
    _ body: (ScreenID, inout ScreenState) -> [Effect]
  ) -> [Effect] {
    guard var screenState = screens[screenID] else { return [] }
    let effects = body(screenID, &screenState)
    screens[screenID] = screenState
    return effects
  }

  mutating func withActiveWorkspace(
    env: ReducerEnv,
    _ body: (ScreenID, WorkspaceID, inout Workspace) -> [Effect]
  ) -> [Effect] {
    withActiveScreen(env: env) { screenID, screenState in
      let wsID = screenState.activeWorkspaceID
      guard var ws = screenState.workspaces[wsID] else { return [] }
      let effects = body(screenID, wsID, &ws)
      screenState.workspaces[wsID] = ws
      return effects
    }
  }

  mutating func withFocusedColumn(
    env: ReducerEnv,
    _ body: (ScreenID, WorkspaceID, inout Column) -> [Effect]
  ) -> [Effect] {
    withActiveWorkspace(env: env) { screenID, wsID, ws in
      guard !ws.columns.isEmpty else { return [] }
      var col = ws.columns[ws.focusedColumnIndex]
      let effects = body(screenID, wsID, &col)
      ws.columns[ws.focusedColumnIndex] = col
      return effects
    }
  }
}
