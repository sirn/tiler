import AppKit
import ApplicationServices

/// Owns the tiling state and orchestrates the event→layout→apply pipeline.
public class WindowManager {
    public var state: TilerState
    public var gaps: GapConfig
    public var workspaceCount: Int
    public var layoutConfig: LayoutConfig
    public var appRules: [AppRuleConfig]

    private let eventBroker: EventBroker

    public init(eventBroker: EventBroker, config: Config = Config.defaults) {
        self.state = TilerState()
        self.gaps = GapConfig(
            outerGaps: config.general.outerGaps,
            innerGaps: config.general.innerGaps,
            columnGaps: config.general.columnGaps
        )
        self.workspaceCount = config.workspaces.count
        self.layoutConfig = config.layout
        self.appRules = config.appRules
        self.eventBroker = eventBroker

        eventBroker.setEventHandler { [weak self] event in
            self?.handle(event)
        }
    }

    public func initializeScreens() {
        let screens = NSScreen.screens
        var screenInfos: [ScreenID: ScreenInfo] = [:]
        var screenWorkspace: [ScreenID: WorkspaceID] = [:]

        for screen in screens {
            let screenID = screen.displayID ?? CGMainDisplayID()
            screenInfos[screenID] = ScreenInfo(
                id: screenID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
            // Each screen gets its own workspace; start with workspace 1
            screenWorkspace[screenID] = 1
        }

        state.screens = screenInfos
        state.screenWorkspace = screenWorkspace

        // Initialize workspaces
        var workspaces: [WorkspaceID: Workspace] = [:]
        for i in 1...workspaceCount {
            workspaces[i] = Workspace(id: i, columns: [], focusedColumnIndex: 0)
        }
        state.workspaces = workspaces

        print("tiler: Initialized \(screenInfos.count) screens, \(workspaceCount) workspaces")
    }

    // MARK: - Config

    /// Apply a new config, updating gaps, workspace count, layout settings, and app rules.
    /// If the workspace count changes, workspaces are re-initialized.
    public func applyConfig(_ config: Config) {
        self.gaps = GapConfig(
            outerGaps: config.general.outerGaps,
            innerGaps: config.general.innerGaps,
            columnGaps: config.general.columnGaps
        )
        self.layoutConfig = config.layout
        self.appRules = config.appRules

        let oldCount = workspaceCount
        self.workspaceCount = config.workspaces.count

        if oldCount != workspaceCount {
            // Re-initialize workspaces to match new count
            var workspaces = state.workspaces
            // Add new workspaces if count increased
            if workspaceCount > oldCount {
                for i in (oldCount + 1)...workspaceCount {
                    workspaces[i] = Workspace(id: i, columns: [], focusedColumnIndex: 0)
                }
            }
            // Remove workspaces beyond new count (migrate their windows to workspace 1)
            for wsID in workspaces.keys where wsID > workspaceCount {
                if let ws = workspaces[wsID], !ws.columns.isEmpty {
                    guard var target = workspaces[1] else { continue }
                    for col in ws.columns {
                        for window in col.windows {
                            if target.columns.isEmpty {
                                target.columns = [Column(windows: [window], focusedWindowIndex: 0, widthFraction: 0.5)]
                                target.focusedColumnIndex = 0
                            } else {
                                target.columns[target.focusedColumnIndex].windows.append(window)
                            }
                        }
                    }
                    workspaces[1] = target
                }
                workspaces.removeValue(forKey: wsID)
            }
            state.workspaces = workspaces
            // Ensure active workspace is still valid
            for (screenID, wsID) in state.screenWorkspace where wsID > workspaceCount {
                state.screenWorkspace[screenID] = 1
            }
        }

        retileAll()
        print("tiler: Applied new config (gaps=\(config.general), workspaces=\(workspaceCount))")
    }

    /// Enumerate all existing windows and add them to the active workspace.
    public func enumerateExistingWindows() {
        let windows = AXWindowBridge.enumerateWindows()
        for (windowID, element, pid, title) in windows {
            guard WindowFilter.isTileable(element) else { continue }
            addWindowToActiveWorkspace(windowID: windowID, element: element, pid: pid, title: title)
        }
        retileActiveWorkspace()
    }

    // MARK: - Event handling

    private func handle(_ event: TilerEvent) {
        switch event {
        case .windowCreated(let windowID, let element, let pid):
            guard WindowFilter.isTileable(element) else { return }
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            let titleStr = title as? String ?? ""
            addWindowToActiveWorkspace(windowID: windowID, element: element, pid: pid, title: titleStr)
            retileActiveWorkspace()

        case .windowDestroyed(_, let pid):
            removeWindowsForPID(pid)
            retileActiveWorkspace()

        case .windowMoved, .windowResized:
            // Ignore for now; could re-evaluate tileability
            break

        case .windowFocused(let windowID, _):
            if let windowID = windowID {
                updateFocus(windowID: windowID)
            }

        case .windowMiniaturized(let windowID, _):
            removeWindow(windowID: windowID)
            retileActiveWorkspace()

        case .windowDeminiaturized(let windowID, let pid):
            // Window came back - re-add it
            if let element = AXWindowBridge.findWindowByID(windowID) {
                guard WindowFilter.isTileable(element) else { return }
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
                addWindowToActiveWorkspace(windowID: windowID, element: element, pid: pid, title: title as? String ?? "")
                retileActiveWorkspace()
            }

        case .appLaunched:
            break

        case .appTerminated(let pid):
            removeWindowsForPID(pid)
            retileActiveWorkspace()

        case .appActivated:
            break
        }
    }

    // MARK: - State mutations

    private func activeScreenID() -> ScreenID? {
        if let keyWindowScreen = NSScreen.main ?? NSScreen.screens.first {
            return keyWindowScreen.displayID ?? CGMainDisplayID()
        }
        return state.screens.keys.first ?? CGMainDisplayID()
    }

    public func activeWorkspaceID() -> WorkspaceID? {
        guard let screenID = activeScreenID() else { return nil }
        return state.screenWorkspace[screenID] ?? 1
    }

    public var activeWorkspace: Workspace? {
        guard let wsID = activeWorkspaceID() else { return nil }
        return state.workspaces[wsID]
    }

    private func addWindowToActiveWorkspace(windowID: CGWindowID, element: AXUIElement, pid: pid_t, title: String) {
        guard let wsID = activeWorkspaceID() else { return }
        
        let node = WindowNode(id: windowID, axElement: element, pid: pid, title: title)
        guard var workspace = state.workspaces[wsID] else { return }
        
        // Niri-like: each new window gets its own column, unless the focused column is empty
        if workspace.columns.isEmpty {
            let column = Column(windows: [node], focusedWindowIndex: 0, widthFraction: 0.5)
            workspace.columns = [column]
            workspace.focusedColumnIndex = 0
        } else if workspace.columns[workspace.focusedColumnIndex].windows.isEmpty {
            // Focused column is empty, add window there
            var col = workspace.columns[workspace.focusedColumnIndex]
            col.windows = [node]
            col.focusedWindowIndex = 0
            workspace.columns[workspace.focusedColumnIndex] = col
        } else {
            // Create a new column for this window
            let column = Column(windows: [node], focusedWindowIndex: 0, widthFraction: 0.5)
            workspace.columns.append(column)
            workspace.focusedColumnIndex = workspace.columns.count - 1
        }
        
        state.workspaces[wsID] = workspace
        print("tiler: Added window \(windowID) (\(title)) to workspace \(wsID) column \(workspace.focusedColumnIndex)")
    }

    private func removeWindow(windowID: CGWindowID) {
        for (wsID, var workspace) in state.workspaces {
            for (colIdx, var column) in workspace.columns.enumerated() {
                if let removeIdx = column.windows.firstIndex(where: { $0.id == windowID }) {
                    column.windows.remove(at: removeIdx)

                    if column.windows.isEmpty {
                        workspace.columns.remove(at: colIdx)
                        if workspace.focusedColumnIndex >= workspace.columns.count && !workspace.columns.isEmpty {
                            workspace.focusedColumnIndex = workspace.columns.count - 1
                        }
                    } else {
                        if column.focusedWindowIndex >= column.windows.count {
                            column.focusedWindowIndex = column.windows.count - 1
                        }
                        workspace.columns[colIdx] = column
                    }

                    state.workspaces[wsID] = workspace
                    print("tiler: Removed window \(windowID) from workspace \(wsID)")
                    return
                }
            }
        }
    }

    private func removeWindowsForPID(_ pid: pid_t) {
        for (wsID, var workspace) in state.workspaces {
            var changed = false
            workspace.columns.removeAll { column in
                let hasPID = column.windows.contains(where: { $0.pid == pid })
                if hasPID { changed = true }
                return hasPID
            }
            if workspace.focusedColumnIndex >= workspace.columns.count && !workspace.columns.isEmpty {
                workspace.focusedColumnIndex = workspace.columns.count - 1
            }
            if changed {
                state.workspaces[wsID] = workspace
            }
        }
    }

    private func updateFocus(windowID: CGWindowID) {
        for (wsID, var workspace) in state.workspaces {
            for (colIdx, var column) in workspace.columns.enumerated() {
                if let winIdx = column.windows.firstIndex(where: { $0.id == windowID }) {
                    column.focusedWindowIndex = winIdx
                    workspace.columns[colIdx] = column
                    workspace.focusedColumnIndex = colIdx
                    state.workspaces[wsID] = workspace
                    return
                }
            }
        }
    }

    // MARK: - Action handling

    public func handleAction(_ action: Action) {
        switch action {

        case .focusColumnLeft:
            guard let wsID = activeWorkspaceID(),
                  var workspace = state.workspaces[wsID],
                  workspace.focusedColumnIndex > 0 else { return }
            workspace.focusedColumnIndex -= 1
            state.workspaces[wsID] = workspace
            focusFocusedWindow(in: workspace)
            retileActiveWorkspace()

        case .focusColumnRight:
            guard let wsID = activeWorkspaceID(),
                  var workspace = state.workspaces[wsID],
                  workspace.focusedColumnIndex < workspace.columns.count - 1 else { return }
            workspace.focusedColumnIndex += 1
            state.workspaces[wsID] = workspace
            focusFocusedWindow(in: workspace)
            retileActiveWorkspace()

        case .moveColumnLeft:
            guard let wsID = activeWorkspaceID(),
                  var workspace = state.workspaces[wsID],
                  workspace.focusedColumnIndex > 0 else { return }
            let idx = workspace.focusedColumnIndex
            workspace.columns.swapAt(idx, idx - 1)
            workspace.focusedColumnIndex -= 1
            state.workspaces[wsID] = workspace
            retileActiveWorkspace()

        case .moveColumnRight:
            guard let wsID = activeWorkspaceID(),
                  var workspace = state.workspaces[wsID],
                  workspace.focusedColumnIndex < workspace.columns.count - 1 else { return }
            let idx = workspace.focusedColumnIndex
            workspace.columns.swapAt(idx, idx + 1)
            workspace.focusedColumnIndex += 1
            state.workspaces[wsID] = workspace
            retileActiveWorkspace()

        case .focusWindowUp:
            guard let wsID = activeWorkspaceID(),
                  var workspace = state.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            var col = workspace.columns[workspace.focusedColumnIndex]
            guard col.focusedWindowIndex > 0 else { return }
            col.focusedWindowIndex -= 1
            workspace.columns[workspace.focusedColumnIndex] = col
            state.workspaces[wsID] = workspace
            focusFocusedWindow(in: workspace)
            retileActiveWorkspace()

        case .focusWindowDown:
            guard let wsID = activeWorkspaceID(),
                  var workspace = state.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            var col = workspace.columns[workspace.focusedColumnIndex]
            guard col.focusedWindowIndex < col.windows.count - 1 else { return }
            col.focusedWindowIndex += 1
            workspace.columns[workspace.focusedColumnIndex] = col
            state.workspaces[wsID] = workspace
            focusFocusedWindow(in: workspace)
            retileActiveWorkspace()

        case .moveWindowUp:
            guard let wsID = activeWorkspaceID(),
                  var workspace = state.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            var col = workspace.columns[workspace.focusedColumnIndex]
            guard col.focusedWindowIndex > 0 else { return }
            let idx = col.focusedWindowIndex
            col.windows.swapAt(idx, idx - 1)
            col.focusedWindowIndex -= 1
            workspace.columns[workspace.focusedColumnIndex] = col
            state.workspaces[wsID] = workspace
            retileActiveWorkspace()

        case .moveWindowDown:
            guard let wsID = activeWorkspaceID(),
                  var workspace = state.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            var col = workspace.columns[workspace.focusedColumnIndex]
            guard col.focusedWindowIndex < col.windows.count - 1 else { return }
            let idx = col.focusedWindowIndex
            col.windows.swapAt(idx, idx + 1)
            col.focusedWindowIndex += 1
            workspace.columns[workspace.focusedColumnIndex] = col
            state.workspaces[wsID] = workspace
            retileActiveWorkspace()

        case .focusWorkspace(let n):
            guard (1...workspaceCount).contains(n) else { return }
            guard let screenID = activeScreenID() else { return }
            let oldWSID = state.screenWorkspace[screenID] ?? 1
            guard oldWSID != n else { return }
            state.screenWorkspace[screenID] = n
            retileAll()
            if let newWorkspace = state.workspaces[n] {
                focusFocusedWindow(in: newWorkspace)
            }
            print("tiler: Switched to workspace \(n)")

        case .moveToWorkspace(let n):
            guard (1...workspaceCount).contains(n) else { return }
            guard let screenID = activeScreenID() else { return }
            let currentWSID = state.screenWorkspace[screenID] ?? 1
            guard currentWSID != n else { return }
            guard var sourceWorkspace = state.workspaces[currentWSID],
                  !sourceWorkspace.columns.isEmpty else { return }

            let colIdx = sourceWorkspace.focusedColumnIndex
            guard colIdx < sourceWorkspace.columns.count else { return }
            var col = sourceWorkspace.columns[colIdx]
            let winIdx = col.focusedWindowIndex
            guard winIdx < col.windows.count else { return }

            // Remove the focused window from the source column
            let window = col.windows.remove(at: winIdx)

            // Update source column after removal
            if col.windows.isEmpty {
                sourceWorkspace.columns.remove(at: colIdx)
                if sourceWorkspace.focusedColumnIndex >= sourceWorkspace.columns.count && !sourceWorkspace.columns.isEmpty {
                    sourceWorkspace.focusedColumnIndex = sourceWorkspace.columns.count - 1
                }
            } else {
                if col.focusedWindowIndex >= col.windows.count {
                    col.focusedWindowIndex = col.windows.count - 1
                }
                sourceWorkspace.columns[colIdx] = col
            }
            state.workspaces[currentWSID] = sourceWorkspace

            // Add the window to the target workspace
            guard var targetWorkspace = state.workspaces[n] else { return }
            if targetWorkspace.columns.isEmpty {
                let newCol = Column(windows: [window], focusedWindowIndex: 0, widthFraction: 0.5)
                targetWorkspace.columns = [newCol]
                targetWorkspace.focusedColumnIndex = 0
            } else {
                // Redistribute width fractions evenly
                let count = CGFloat(targetWorkspace.columns.count + 1)
                for i in 0..<targetWorkspace.columns.count {
                    targetWorkspace.columns[i].widthFraction = 1.0 / count
                }
                let newCol = Column(windows: [window], focusedWindowIndex: 0, widthFraction: 1.0 / count)
                targetWorkspace.columns.append(newCol)
                targetWorkspace.focusedColumnIndex = targetWorkspace.columns.count - 1
            }
            state.workspaces[n] = targetWorkspace

            retileAll()
            print("tiler: Moved window to workspace \(n)")

        case .increaseColumnWidth:
            guard let wsID = activeWorkspaceID(),
                  var workspace = state.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            var col = workspace.columns[workspace.focusedColumnIndex]
            col.widthFraction = min(col.widthFraction + 0.05, 0.8)
            workspace.columns[workspace.focusedColumnIndex] = col
            state.workspaces[wsID] = workspace
            retileActiveWorkspace()

        case .decreaseColumnWidth:
            guard let wsID = activeWorkspaceID(),
                  var workspace = state.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            var col = workspace.columns[workspace.focusedColumnIndex]
            col.widthFraction = max(col.widthFraction - 0.05, 0.2)
            workspace.columns[workspace.focusedColumnIndex] = col
            state.workspaces[wsID] = workspace
            retileActiveWorkspace()

        case .toggleColumnTabbed:
            guard let wsID = activeWorkspaceID(),
                  var workspace = state.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            var col = workspace.columns[workspace.focusedColumnIndex]
            col.mode = (col.mode == .stack) ? .tab : .stack
            workspace.columns[workspace.focusedColumnIndex] = col
            state.workspaces[wsID] = workspace
            retileActiveWorkspace()

        case .closeWindow:
            guard let wsID = activeWorkspaceID(),
                  let workspace = state.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            let col = workspace.columns[workspace.focusedColumnIndex]
            guard col.focusedWindowIndex < col.windows.count else { return }
            let window = col.windows[col.focusedWindowIndex]
            // Press the close button via Accessibility API
            var closeButton: CFTypeRef?
            AXUIElementCopyAttributeValue(window.axElement, kAXCloseButtonAttribute as CFString, &closeButton)
            if let btn = closeButton {
                AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
            }
            // Window removal will be handled by the .windowDestroyed event

        case .toggleFullscreen:
            guard let wsID = activeWorkspaceID(),
                  let workspace = state.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            let col = workspace.columns[workspace.focusedColumnIndex]
            guard col.focusedWindowIndex < col.windows.count else { return }
            let window = col.windows[col.focusedWindowIndex]
            var fullscreen: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(window.axElement, "AXFullscreen" as CFString, &fullscreen)
            if result == .success, let isFullscreen = fullscreen as? Bool {
                AXUIElementSetAttributeValue(window.axElement, "AXFullscreen" as CFString, !isFullscreen as CFTypeRef)
                print("tiler: Toggled fullscreen on window \(window.id)")
            }
        }
    }

    // MARK: - Focus helpers

    private func focusFocusedWindow(in workspace: Workspace) {
        guard !workspace.columns.isEmpty,
              workspace.focusedColumnIndex < workspace.columns.count else { return }
        let col = workspace.columns[workspace.focusedColumnIndex]
        guard col.focusedWindowIndex < col.windows.count else { return }
        let window = col.windows[col.focusedWindowIndex]
        AXUIElementSetAttributeValue(window.axElement, kAXMainAttribute as CFString, true as CFTypeRef)
    }

    // MARK: - Workspace-specific tiling

    private func screenIDForWorkspace(_ wsID: WorkspaceID) -> ScreenID? {
        return state.screenWorkspace.first(where: { $0.value == wsID })?.key
    }

    private func retileWorkspace(_ wsID: WorkspaceID) {
        guard let workspace = state.workspaces[wsID],
              let screenID = screenIDForWorkspace(wsID),
              let screen = state.screens[screenID] else {
            hideWorkspace(wsID)
            return
        }

        let offset = ViewportCalc.computeOffset(workspace: workspace, screen: screen, gaps: gaps)
        let frames = LayoutEngine.layout(workspace: workspace, screen: screen, gaps: gaps, viewportOffset: offset)
        AXWindowBridge.applyFrames(frames)

        if !frames.isEmpty {
            print("tiler: Laid out \(frames.count) windows on workspace \(wsID)")
        }
    }

    private func hideWorkspace(_ wsID: WorkspaceID) {
        guard let workspace = state.workspaces[wsID] else { return }
        var frames: [CGWindowID: NSRect] = [:]
        for column in workspace.columns {
            for window in column.windows {
                frames[window.id] = NSRect(x: -100000, y: 0, width: 100, height: 100)
            }
        }
        if !frames.isEmpty {
            AXWindowBridge.applyFrames(frames)
        }
    }

    private func retileAll() {
        guard let activeWSID = activeWorkspaceID() else { return }
        retileWorkspace(activeWSID)
        for wsID in state.workspaces.keys where wsID != activeWSID {
            hideWorkspace(wsID)
        }
    }

    // MARK: - Layout

    public func retileActiveWorkspace() {
        guard let wsID = activeWorkspaceID(),
              let workspace = state.workspaces[wsID],
              let screenID = activeScreenID(),
              let screen = state.screens[screenID] else {
            return
        }

        let offset = ViewportCalc.computeOffset(workspace: workspace, screen: screen, gaps: gaps)
        let frames = LayoutEngine.layout(workspace: workspace, screen: screen, gaps: gaps, viewportOffset: offset)

        AXWindowBridge.applyFrames(frames)

        if !frames.isEmpty {
            print("tiler: Laid out \(frames.count) windows on workspace \(wsID)")
        }
    }
}
