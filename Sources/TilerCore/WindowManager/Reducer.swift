import CoreGraphics

enum Reducer {

  /// Operate on the active screen (derived from env). Mutates state and writes back.
  /// Returns [] when there is no active screen.
  private static func withActiveScreen(
    _ state: inout TilerState, env: ReducerEnv,
    _ body: (ScreenID, inout ScreenState) -> [Effect]
  ) -> [Effect] {
    guard let screenID = env.activeScreenID,
          var screenState = state.screens[screenID] else { return [] }
    let effects = body(screenID, &screenState)
    state.screens[screenID] = screenState
    return effects
  }

  /// Operate on the active workspace of the active screen (derived from state, not env).
  /// Mutates state and writes back. Returns [] when there is no active screen or workspace.
  private static func withActiveWorkspace(
    _ state: inout TilerState, env: ReducerEnv,
    _ body: (ScreenID, WorkspaceID, inout Workspace) -> [Effect]
  ) -> [Effect] {
    withActiveScreen(&state, env: env) { screenID, screenState in
      let wsID = screenState.activeWorkspaceID
      guard var ws = screenState.workspaces[wsID] else { return [] }
      let effects = body(screenID, wsID, &ws)
      screenState.workspaces[wsID] = ws
      return effects
    }
  }

  // MARK: - Action reducer

  static func apply(
    _ action: Action,
    to state: inout TilerState,
    env: ReducerEnv
  ) -> [Effect] {
    switch action {
    case .focusColumnLeft:
      return withActiveWorkspace(&state, env: env) { screenID, wsID, ws in
        guard ws.focusedColumnIndex > 0 else { return [] }
        ws.focusedColumnIndex -= 1
        return [.focusFocusedWindow(screenID, wsID), .retile]
      }

    case .focusColumnRight:
      return withActiveWorkspace(&state, env: env) { screenID, wsID, ws in
        guard ws.focusedColumnIndex < ws.columns.count - 1 else { return [] }
        ws.focusedColumnIndex += 1
        return [.focusFocusedWindow(screenID, wsID), .retile]
      }

    case .moveColumnLeft:
      return withActiveWorkspace(&state, env: env) { _, _, ws in
        guard ws.focusedColumnIndex > 0 else { return [] }
        let idx = ws.focusedColumnIndex
        ws.columns.swapAt(idx, idx - 1)
        ws.focusedColumnIndex = idx - 1
        return [.retile]
      }

    case .moveColumnRight:
      return withActiveWorkspace(&state, env: env) { _, _, ws in
        guard ws.focusedColumnIndex < ws.columns.count - 1 else { return [] }
        let idx = ws.focusedColumnIndex
        ws.columns.swapAt(idx, idx + 1)
        ws.focusedColumnIndex = idx + 1
        return [.retile]
      }

    case .focusWindowUp:
      return withActiveWorkspace(&state, env: env) { screenID, wsID, ws in
        guard !ws.columns.isEmpty else { return [] }
        var col = ws.columns[ws.focusedColumnIndex]
        guard col.focusedWindowIndex > 0 else { return [] }
        col.focusedWindowIndex -= 1
        ws.columns[ws.focusedColumnIndex] = col
        return [.focusFocusedWindow(screenID, wsID), .retile]
      }

    case .focusWindowDown:
      return withActiveWorkspace(&state, env: env) { screenID, wsID, ws in
        guard !ws.columns.isEmpty else { return [] }
        var col = ws.columns[ws.focusedColumnIndex]
        guard col.focusedWindowIndex < col.windows.count - 1 else { return [] }
        col.focusedWindowIndex += 1
        ws.columns[ws.focusedColumnIndex] = col
        return [.focusFocusedWindow(screenID, wsID), .retile]
      }

    case .moveWindowUp:
      return withActiveWorkspace(&state, env: env) { _, _, ws in
        guard !ws.columns.isEmpty else { return [] }
        var col = ws.columns[ws.focusedColumnIndex]
        guard col.focusedWindowIndex > 0 else { return [] }
        let idx = col.focusedWindowIndex
        col.windows.swapAt(idx, idx - 1)
        col.focusedWindowIndex = idx - 1
        ws.columns[ws.focusedColumnIndex] = col
        return [.retile]
      }

    case .moveWindowDown:
      return withActiveWorkspace(&state, env: env) { _, _, ws in
        guard !ws.columns.isEmpty else { return [] }
        var col = ws.columns[ws.focusedColumnIndex]
        guard col.focusedWindowIndex < col.windows.count - 1 else { return [] }
        let idx = col.focusedWindowIndex
        col.windows.swapAt(idx, idx + 1)
        col.focusedWindowIndex = idx + 1
        ws.columns[ws.focusedColumnIndex] = col
        return [.retile]
      }

    case .focusWorkspace(let n):
      return withActiveScreen(&state, env: env) { screenID, screenState in
        guard (1...env.workspaceCount).contains(n),
              screenState.activeWorkspaceID != n
        else { return [] }
        screenState.activeWorkspaceID = n
        return [.retile, .focusFocusedWindow(screenID, n),
                .log("Switched to workspace \(n)")]
      }

    case .moveToWorkspace(let n):
      return withActiveScreen(&state, env: env) { _, screenState in
        guard (1...env.workspaceCount).contains(n) else { return [] }
        let currentWSID = screenState.activeWorkspaceID
        guard currentWSID != n,
              var sourceWorkspace = screenState.workspaces[currentWSID],
              !sourceWorkspace.columns.isEmpty,
              var targetWorkspace = screenState.workspaces[n]
        else { return [] }

        let colIdx = sourceWorkspace.focusedColumnIndex
        guard colIdx < sourceWorkspace.columns.count else { return [] }
        var col = sourceWorkspace.columns[colIdx]
        let winIdx = col.focusedWindowIndex
        guard winIdx < col.windows.count else { return [] }

        let window = col.windows.remove(at: winIdx)

        if col.windows.isEmpty {
          sourceWorkspace.columns.remove(at: colIdx)
          if sourceWorkspace.focusedColumnIndex >= sourceWorkspace.columns.count
            && !sourceWorkspace.columns.isEmpty {
            sourceWorkspace.focusedColumnIndex = sourceWorkspace.columns.count - 1
          }
        } else {
          if col.focusedWindowIndex >= col.windows.count {
            col.focusedWindowIndex = col.windows.count - 1
          }
          sourceWorkspace.columns[colIdx] = col
        }
        screenState.workspaces[currentWSID] = sourceWorkspace

        let newCol = Column(
          windows: [window], focusedWindowIndex: 0, widthFraction: env.defaultColumnWidth)
        if targetWorkspace.columns.isEmpty {
          targetWorkspace.columns = [newCol]
          targetWorkspace.focusedColumnIndex = 0
        } else {
          let insertAt = min(targetWorkspace.focusedColumnIndex + 1, targetWorkspace.columns.count)
          targetWorkspace.columns.insert(newCol, at: insertAt)
          targetWorkspace.focusedColumnIndex = insertAt
        }
        screenState.workspaces[n] = targetWorkspace

        return [.retile, .log("Moved window to workspace \(n)")]
      }

    case .increaseColumnWidth:
      return withActiveWorkspace(&state, env: env) { _, _, ws in
        guard !ws.columns.isEmpty else { return [] }
        var col = ws.columns[ws.focusedColumnIndex]
        col.widthFraction = min(col.widthFraction + 0.05, 0.8)
        col.measuredMinWidth = nil
        ws.columns[ws.focusedColumnIndex] = col
        return [.retile]
      }

    case .decreaseColumnWidth:
      return withActiveWorkspace(&state, env: env) { _, _, ws in
        guard !ws.columns.isEmpty else { return [] }
        var col = ws.columns[ws.focusedColumnIndex]
        col.widthFraction = max(col.widthFraction - 0.05, 0.2)
        col.measuredMinWidth = nil
        ws.columns[ws.focusedColumnIndex] = col
        return [.retile]
      }

    case .toggleColumnTabbed:
      return withActiveWorkspace(&state, env: env) { _, _, ws in
        guard !ws.columns.isEmpty else { return [] }
        var col = ws.columns[ws.focusedColumnIndex]
        col.mode = (col.mode == .stack) ? .tab : .stack
        ws.columns[ws.focusedColumnIndex] = col
        return [.retile]
      }

    case .closeWindow:
      return withActiveWorkspace(&state, env: env) { _, _, ws in
        guard !ws.columns.isEmpty else { return [] }
        let col = ws.columns[ws.focusedColumnIndex]
        guard col.focusedWindowIndex < col.windows.count else { return [] }
        let window = col.windows[col.focusedWindowIndex]
        return [.closeWindow(window.id)]
      }

    case .toggleFullscreen:
      return withActiveWorkspace(&state, env: env) { _, _, ws in
        guard !ws.columns.isEmpty else { return [] }
        let col = ws.columns[ws.focusedColumnIndex]
        guard col.focusedWindowIndex < col.windows.count else { return [] }
        let window = col.windows[col.focusedWindowIndex]
        return [.toggleFullscreen(window.id)]
      }

    case .consumeOrExpelLeft:
      return applyConsumeOrExpel(.left, to: &state, env: env)
    case .consumeOrExpelRight:
      return applyConsumeOrExpel(.right, to: &state, env: env)
    }
  }

  // MARK: - Consume / expel helper

  private static func applyConsumeOrExpel(
    _ direction: HorizontalDirection,
    to state: inout TilerState,
    env: ReducerEnv
  ) -> [Effect] {
    withActiveWorkspace(&state, env: env) { screenID, _, ws in
      guard let result = consumeOrExpel(
        columns: ws.columns,
        focusedColumnIndex: ws.focusedColumnIndex,
        direction: direction)
      else { return [] }
      ws.columns = result.columns
      ws.focusedColumnIndex = result.focusedColumnIndex
      return [.refreshTabs(screenID, ws.id), .scheduleDeferredTabRefresh(screenID, ws.id), .retile]
    }
  }
}
