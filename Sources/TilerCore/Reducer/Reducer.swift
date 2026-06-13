import CoreGraphics

private let columnWidthIncrement: CGFloat = 0.05
private let columnWidthMax: CGFloat = 0.8
private let columnWidthMin: CGFloat = 0.2

enum Reducer {

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
    if let screenID = env.activeScreenID,
       let ss = state.screens[screenID],
       let currentWS = ss.workspaces[ss.activeWorkspaceID],
       !currentWS.columns.isEmpty,
       currentWS.focusedColumnIndex == 0,
         let currentIdx = env.orderedScreenIDs.firstIndex(of: screenID),
         env.orderedScreenIDs.count > 1 {
          let prevID = env.orderedScreenIDs[(currentIdx - 1 + env.orderedScreenIDs.count) % env.orderedScreenIDs.count]
          return state.withScreen(prevID) { prevID, prevScreen in
              let wsID = prevScreen.activeWorkspaceID
              guard var ws = prevScreen.workspaces[wsID], !ws.columns.isEmpty else { return [] }
            ws.focusedColumnIndex = ws.columns.count - 1
              prevScreen.workspaces[wsID] = ws
              return [.focusFocusedWindow(prevID, wsID), .retile]
          }
      }
      return state.withActiveWorkspace(env: env) { screenID, wsID, ws in
          guard ws.focusedColumnIndex > 0 else { return [] }
          ws.focusedColumnIndex -= 1
          return [.focusFocusedWindow(screenID, wsID), .retile]
      }

    case .focusColumnRight:
      if let screenID = env.activeScreenID,
         let ss = state.screens[screenID],
       let ws = ss.workspaces[ss.activeWorkspaceID],
       !ws.columns.isEmpty,
       ws.focusedColumnIndex >= ws.columns.count - 1,
         let currentIdx = env.orderedScreenIDs.firstIndex(of: screenID),
         env.orderedScreenIDs.count > 1 {
          let nextID = env.orderedScreenIDs[(currentIdx + 1) % env.orderedScreenIDs.count]
          return state.withScreen(nextID) { nextID, nextScreen in
              let wsID = nextScreen.activeWorkspaceID
              guard var ws = nextScreen.workspaces[wsID], !ws.columns.isEmpty else { return [] }
              ws.focusedColumnIndex = 0
              nextScreen.workspaces[wsID] = ws
              return [.focusFocusedWindow(nextID, wsID), .retile]
          }
      }
      return state.withActiveWorkspace(env: env) { screenID, wsID, ws in
          guard ws.focusedColumnIndex < ws.columns.count - 1 else { return [] }
          ws.focusedColumnIndex += 1
          return [.focusFocusedWindow(screenID, wsID), .retile]
      }

    case .moveColumnLeft:
      return state.withActiveWorkspace(env: env) { _, _, ws in
        guard ws.focusedColumnIndex > 0 else { return [] }
        let idx = ws.focusedColumnIndex
        ws.columns.swapAt(idx, idx - 1)
        ws.focusedColumnIndex = idx - 1
        return [.retile]
      }

    case .moveColumnRight:
      return state.withActiveWorkspace(env: env) { _, _, ws in
        guard ws.focusedColumnIndex < ws.columns.count - 1 else { return [] }
        let idx = ws.focusedColumnIndex
        ws.columns.swapAt(idx, idx + 1)
        ws.focusedColumnIndex = idx + 1
        return [.retile]
      }

    case .focusWindowUp:
      return state.withFocusedColumn(env: env) { screenID, wsID, col in
        let count = col.windows.count
        if count <= 1 { return [] }
        if col.mode == .tab {
          col.focusedWindowIndex = (col.focusedWindowIndex - 1 + count) % count
        } else {
          guard col.focusedWindowIndex > 0 else { return [] }
          col.focusedWindowIndex -= 1
        }
        return [.raiseTabbedWindows(screenID, wsID), .focusFocusedWindow(screenID, wsID), .retile]
      }

    case .focusWindowDown:
      return state.withFocusedColumn(env: env) { screenID, wsID, col in
        let count = col.windows.count
        if count <= 1 { return [] }
        if col.mode == .tab {
          col.focusedWindowIndex = (col.focusedWindowIndex + 1) % count
        } else {
          guard col.focusedWindowIndex < count - 1 else { return [] }
          col.focusedWindowIndex += 1
        }
        return [.raiseTabbedWindows(screenID, wsID), .focusFocusedWindow(screenID, wsID), .retile]
      }

    case .moveWindowUp:
      return state.withFocusedColumn(env: env) { _, _, col in
        guard col.focusedWindowIndex > 0 else { return [] }
        let idx = col.focusedWindowIndex
        col.windows.swapAt(idx, idx - 1)
        col.focusedWindowIndex = idx - 1
        return [.retile]
      }

    case .moveWindowDown:
      return state.withFocusedColumn(env: env) { _, _, col in
        guard col.focusedWindowIndex < col.windows.count - 1 else { return [] }
        let idx = col.focusedWindowIndex
        col.windows.swapAt(idx, idx + 1)
        col.focusedWindowIndex = idx + 1
        return [.retile]
      }

    case .focusWorkspace(let n):
      return state.withActiveScreen(env: env) { screenID, screenState in
        guard (1...env.workspaceCount).contains(n),
              screenState.activeWorkspaceID != n
        else { return [] }
        screenState.activeWorkspaceID = n
        return [.retile, .focusFocusedWindow(screenID, n),
                .log("Switched to workspace \(n)")]
      }

    case .moveToWorkspace(let n):
      return state.withActiveScreen(env: env) { _, screenState in
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
          windows: [window], focusedWindowIndex: 0, widthFraction: col.widthFraction)
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

    case .focusScreenPrevious:
      if let screenID = env.activeScreenID,
         let currentIdx = env.orderedScreenIDs.firstIndex(of: screenID),
         env.orderedScreenIDs.count > 1 {
        let prevID = env.orderedScreenIDs[(currentIdx - 1 + env.orderedScreenIDs.count) % env.orderedScreenIDs.count]
        return state.withScreen(prevID) { prevID, prevScreen in
          let wsID = prevScreen.activeWorkspaceID
          guard let ws = prevScreen.workspaces[wsID], !ws.columns.isEmpty else { return [] }
          return [.focusFocusedWindow(prevID, wsID)]
        }
      }
      return []

    case .focusScreenNext:
      if let screenID = env.activeScreenID,
         let currentIdx = env.orderedScreenIDs.firstIndex(of: screenID),
         env.orderedScreenIDs.count > 1 {
        let nextID = env.orderedScreenIDs[(currentIdx + 1) % env.orderedScreenIDs.count]
        return state.withScreen(nextID) { nextID, nextScreen in
          let wsID = nextScreen.activeWorkspaceID
          guard let ws = nextScreen.workspaces[wsID], !ws.columns.isEmpty else { return [] }
          return [.focusFocusedWindow(nextID, wsID)]
        }
      }
      return []

    case .moveToScreenPrevious:
      guard let screenID = env.activeScreenID,
            let currentIdx = env.orderedScreenIDs.firstIndex(of: screenID),
            env.orderedScreenIDs.count > 1
      else { return [] }
      let targetID = env.orderedScreenIDs[(currentIdx - 1 + env.orderedScreenIDs.count) % env.orderedScreenIDs.count]

      // Extract window from source screen
      var extractedWindow: WindowNode?
      var extractedWidthFraction: CGFloat = 0.5
      let sourceEffects = state.withActiveScreen(env: env) { _, screenState in
        let currentWSID = screenState.activeWorkspaceID
        guard var sourceWorkspace = screenState.workspaces[currentWSID],
              !sourceWorkspace.columns.isEmpty else { return [] }
        let colIdx = sourceWorkspace.focusedColumnIndex
        guard colIdx < sourceWorkspace.columns.count else { return [] }
        var col = sourceWorkspace.columns[colIdx]
        let winIdx = col.focusedWindowIndex
        guard winIdx < col.windows.count else { return [] }

        let window = col.windows.remove(at: winIdx)
        extractedWindow = window
        extractedWidthFraction = col.widthFraction

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
        return [.retile]
      }

      guard let window = extractedWindow else { return sourceEffects }

      // Insert window into target screen
      let targetEffects = state.withScreen(targetID) { targetID, targetScreen in
        let targetWSID = targetScreen.activeWorkspaceID
        guard var targetWorkspace = targetScreen.workspaces[targetWSID] else { return [] }

        let newCol = Column(
          windows: [window], focusedWindowIndex: 0, widthFraction: extractedWidthFraction)
        if targetWorkspace.columns.isEmpty {
          targetWorkspace.columns = [newCol]
          targetWorkspace.focusedColumnIndex = 0
        } else {
          let insertAt = min(targetWorkspace.focusedColumnIndex + 1, targetWorkspace.columns.count)
          targetWorkspace.columns.insert(newCol, at: insertAt)
          targetWorkspace.focusedColumnIndex = insertAt
        }
        targetScreen.workspaces[targetWSID] = targetWorkspace

        return [.retile, .focusFocusedWindow(targetID, targetWSID), .log("Moved window to screen \(targetID)")]
      }

      return sourceEffects + targetEffects

    case .moveToScreenNext:
      guard let screenID = env.activeScreenID,
            let currentIdx = env.orderedScreenIDs.firstIndex(of: screenID),
            env.orderedScreenIDs.count > 1
      else { return [] }
      let targetID = env.orderedScreenIDs[(currentIdx + 1) % env.orderedScreenIDs.count]

      // Extract window from source screen
      var extractedWindow: WindowNode?
      var extractedWidthFraction: CGFloat = 0.5
      let sourceEffects = state.withActiveScreen(env: env) { _, screenState in
        let currentWSID = screenState.activeWorkspaceID
        guard var sourceWorkspace = screenState.workspaces[currentWSID],
              !sourceWorkspace.columns.isEmpty else { return [] }
        let colIdx = sourceWorkspace.focusedColumnIndex
        guard colIdx < sourceWorkspace.columns.count else { return [] }
        var col = sourceWorkspace.columns[colIdx]
        let winIdx = col.focusedWindowIndex
        guard winIdx < col.windows.count else { return [] }

        let window = col.windows.remove(at: winIdx)
        extractedWindow = window
        extractedWidthFraction = col.widthFraction

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
        return [.retile]
      }

      guard let window = extractedWindow else { return sourceEffects }

      // Insert window into target screen
      let targetEffects = state.withScreen(targetID) { targetID, targetScreen in
        let targetWSID = targetScreen.activeWorkspaceID
        guard var targetWorkspace = targetScreen.workspaces[targetWSID] else { return [] }

        let newCol = Column(
          windows: [window], focusedWindowIndex: 0, widthFraction: extractedWidthFraction)
        if targetWorkspace.columns.isEmpty {
          targetWorkspace.columns = [newCol]
          targetWorkspace.focusedColumnIndex = 0
        } else {
          let insertAt = min(targetWorkspace.focusedColumnIndex + 1, targetWorkspace.columns.count)
          targetWorkspace.columns.insert(newCol, at: insertAt)
          targetWorkspace.focusedColumnIndex = insertAt
        }
        targetScreen.workspaces[targetWSID] = targetWorkspace

        return [.retile, .focusFocusedWindow(targetID, targetWSID), .log("Moved window to screen \(targetID)")]
      }

      return sourceEffects + targetEffects

    case .increaseColumnWidth:
      return state.withFocusedColumn(env: env) { _, _, col in
        adjustColumnWidth(&col, by: columnWidthIncrement)
        return [.retile]
      }

    case .decreaseColumnWidth:
      return state.withFocusedColumn(env: env) { _, _, col in
        adjustColumnWidth(&col, by: -columnWidthIncrement)
        return [.retile]
      }

    case .toggleColumnTabbed:
      return state.withFocusedColumn(env: env) { _, _, col in
        col.mode = (col.mode == .stack) ? .tab : .stack
        return [.retile]
      }

    case .closeWindow:
      return state.withFocusedColumn(env: env) { _, _, col in
        guard let window = Self.focusedWindow(in: col) else { return [] }
        return [.closeWindow(window.id)]
      }

    case .toggleFullscreen:
      return state.withFocusedColumn(env: env) { _, _, col in
        guard let window = Self.focusedWindow(in: col) else { return [] }
        return [.toggleFullscreen(window.id)]
      }

    case .consumeOrExpelLeft:
      return applyConsumeOrExpel(.left, to: &state, env: env)
    case .consumeOrExpelRight:
      return applyConsumeOrExpel(.right, to: &state, env: env)
    case .dumpFrameState:
      return []
    }
  }

  // MARK: - Consume / expel helper

  private static func applyConsumeOrExpel(
    _ direction: Workspace.HorizontalDirection,
    to state: inout TilerState,
    env: ReducerEnv
  ) -> [Effect] {
    state.withActiveWorkspace(env: env) { screenID, wsID, ws in
      guard ws.consumeOrExpel(direction: direction) else { return [] }
      return [.refreshTabs(screenID, wsID), .scheduleDeferredTabRefresh(screenID, wsID), .retile]
    }
  }
}
