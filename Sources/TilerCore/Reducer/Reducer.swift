import CoreGraphics

private let columnWidthIncrement: CGFloat = 0.05
private let columnWidthMax: CGFloat = 0.8
private let columnWidthMin: CGFloat = 0.2

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

  /// Operate on the focused column of the active workspace (derived from state).
  /// Mutates state and writes back. Returns [] when there is no active screen, workspace,
  /// or when the workspace has no columns.
  private static func withFocusedColumn(
    _ state: inout TilerState, env: ReducerEnv,
    _ body: (ScreenID, WorkspaceID, inout Column) -> [Effect]
  ) -> [Effect] {
    withActiveWorkspace(&state, env: env) { screenID, wsID, ws in
      guard !ws.columns.isEmpty else { return [] }
      var col = ws.columns[ws.focusedColumnIndex]
      let effects = body(screenID, wsID, &col)
      ws.columns[ws.focusedColumnIndex] = col
      return effects
    }
  }
  /// Returns the focused window from a column, or nil if index is out of bounds.
  private static func focusedWindow(in col: Column) -> WindowNode? {
    guard col.focusedWindowIndex < col.windows.count else { return nil }
    return col.windows[col.focusedWindowIndex]
  }
  private static func adjustColumnWidth(_ col: inout Column, by delta: CGFloat, min minWidth: CGFloat = columnWidthMin, max maxWidth: CGFloat = columnWidthMax) {
    col.widthFraction = min(max(col.widthFraction + delta, minWidth), maxWidth)
    col.measuredMinWidth = nil
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
      return withFocusedColumn(&state, env: env) { screenID, wsID, col in
        guard col.focusedWindowIndex > 0 else { return [] }
        col.focusedWindowIndex -= 1
        return [.focusFocusedWindow(screenID, wsID), .retile]
      }

    case .focusWindowDown:
      return withFocusedColumn(&state, env: env) { screenID, wsID, col in
        guard col.focusedWindowIndex < col.windows.count - 1 else { return [] }
        col.focusedWindowIndex += 1
        return [.focusFocusedWindow(screenID, wsID), .retile]
      }

    case .moveWindowUp:
      return withFocusedColumn(&state, env: env) { _, _, col in
        guard col.focusedWindowIndex > 0 else { return [] }
        let idx = col.focusedWindowIndex
        col.windows.swapAt(idx, idx - 1)
        col.focusedWindowIndex = idx - 1
        return [.retile]
      }

    case .moveWindowDown:
      return withFocusedColumn(&state, env: env) { _, _, col in
        guard col.focusedWindowIndex < col.windows.count - 1 else { return [] }
        let idx = col.focusedWindowIndex
        col.windows.swapAt(idx, idx + 1)
        col.focusedWindowIndex = idx + 1
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
        guard currentWSID != n else { return [] }
        guard var sourceWorkspace = screenState.workspaces[currentWSID],
              !sourceWorkspace.columns.isEmpty else { return [] }
        guard var targetWorkspace = screenState.workspaces[n] else { return [] }

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
      return withFocusedColumn(&state, env: env) { _, _, col in
        adjustColumnWidth(&col, by: columnWidthIncrement)
        return [.retile]
      }

    case .decreaseColumnWidth:
      return withFocusedColumn(&state, env: env) { _, _, col in
        adjustColumnWidth(&col, by: -columnWidthIncrement)
        return [.retile]
      }

    case .toggleColumnTabbed:
      return withFocusedColumn(&state, env: env) { _, _, col in
        col.mode = (col.mode == .stack) ? .tab : .stack
        return [.retile]
      }

    case .closeWindow:
      return withFocusedColumn(&state, env: env) { _, _, col in
        guard let window = Self.focusedWindow(in: col) else { return [] }
        return [.closeWindow(window.id)]
      }

    case .toggleFullscreen:
      return withFocusedColumn(&state, env: env) { _, _, col in
        guard let window = Self.focusedWindow(in: col) else { return [] }
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
    withActiveWorkspace(&state, env: env) { screenID, wsID, ws in
      guard let result = consumeOrExpel(
        columns: ws.columns,
        focusedColumnIndex: ws.focusedColumnIndex,
        direction: direction)
      else { return [] }
      ws.columns = result.columns
      ws.focusedColumnIndex = result.focusedColumnIndex
      return [.refreshTabs(screenID, wsID), .scheduleDeferredTabRefresh(screenID, wsID), .retile]
    }
  }
}
