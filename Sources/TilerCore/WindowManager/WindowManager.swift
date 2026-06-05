import AppKit
import ApplicationServices
import CoreGraphics

/// Owns the tiling state and orchestrates the event→layout→apply pipeline.
public class WindowManager {
    public var state: TilerState
    public var gaps: GapConfig
    public var workspaceCount: Int
    public var layoutConfig: LayoutConfig
    public var appRules: [AppRuleConfig]

    public let windowStore = WindowStore()
    private let eventBroker: EventBroker

    // Coalescing flags
    private var needsReconcile = false
    private var needsRetile = false
    private var drainScheduled = false

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

        eventBroker.onEvent = { [weak self] event in
            self?.handleEvent(event)
        }
    }

    public func start() {
        scheduleDrain()
    }

    // MARK: - Coalescing drain

    private func setNeedsReconcile() {
        needsReconcile = true
        scheduleDrain()
    }

    private func setNeedsRetile() {
        needsRetile = true
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard !drainScheduled else { return }
        drainScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        drainScheduled = false
        if needsReconcile {
            needsReconcile = false
            reconcile()
        }
        if needsRetile {
            needsRetile = false
            retileActiveWorkspace()
        }
    }

    // MARK: - Screen & workspace setup

    public func initializeScreens() {
        let screens = NSScreen.screens
        var screenStates: [ScreenID: ScreenState] = [:]

        for screen in screens {
            let screenID = screen.displayID ?? CGMainDisplayID()
            let info = ScreenInfo(
                id: screenID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )

            var workspaces: [WorkspaceID: Workspace] = [:]
            for i in 1...workspaceCount {
                workspaces[i] = Workspace(id: i, columns: [], focusedColumnIndex: 0)
            }

            screenStates[screenID] = ScreenState(
                info: info,
                workspaces: workspaces,
                activeWorkspaceID: 1
            )
        }

        state.screens = screenStates

        tiler_log("Initialized \(screenStates.count) screens, \(workspaceCount) workspaces each")
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
            for (screenID, var screenState) in state.screens {
                var workspaces = screenState.workspaces

                if workspaceCount > oldCount {
                    for i in (oldCount + 1)...workspaceCount {
                        workspaces[i] = Workspace(id: i, columns: [], focusedColumnIndex: 0)
                    }
                }

                for wsID in workspaces.keys where wsID > workspaceCount {
                    if let ws = workspaces[wsID], !ws.columns.isEmpty {
                        guard var target = workspaces[1] else { continue }
                        for col in ws.columns {
                            for window in col.windows {
                                if target.columns.isEmpty {
                                    target.columns = [Column(windows: [window], focusedWindowIndex: 0, widthFraction: layoutConfig.defaultColumnWidth)]
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

                screenState.workspaces = workspaces
                if screenState.activeWorkspaceID > workspaceCount {
                    screenState.activeWorkspaceID = 1
                }
                state.screens[screenID] = screenState
            }
        }

        setNeedsRetile()
        tiler_log("Applied new config (gaps=\(config.general), workspaces=\(workspaceCount))")
    }

    // MARK: - Event handling

    private func handleEvent(_ event: TilerEvent) {
        switch event {
        case .appLaunched:
            setNeedsReconcile()
        case .appTerminated(let pid):
            windowStore.forget(pid: pid)
            removeWindowsForPID(pid)
            setNeedsRetile()
        case .windowCreated:
            setNeedsReconcile()
        case .windowDestroyed:
            setNeedsReconcile()
        case .windowMinimized:
            setNeedsReconcile()
        case .windowDeminimized:
            setNeedsReconcile()
        case .focusChanged(let pid, let element):
            handleFocusChanged(pid: pid, element: element)
        case .geometryChanged:
            // Ignored — these are echoes from our own retile
            break
        }
    }

    public func reconcile() {
        windowStore.refresh()

        // Build tileable set from CGWindowList + WindowStore
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            tiler_log("reconcile: Could not get window list")
            return
        }

        var tileableIDs: Set<CGWindowID> = []
        var windowInfo: [CGWindowID: (pid: pid_t, title: String)] = [:]

        for info in windowList {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer <= 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }

            let title = info[kCGWindowName as String] as? String ?? ""
            windowInfo[wid] = (pid, title)

            if let element = windowStore.element(for: wid), WindowFilter.isTileable(element) {
                tileableIDs.insert(wid)
            }
        }

        // Remove windows that are no longer tileable
        var membershipChanged = false
        for (screenID, var screenState) in state.screens {
            for (wsID, var workspace) in screenState.workspaces {
                var changed = false
                for colIdx in workspace.columns.indices.reversed() {
                    let before = workspace.columns[colIdx].windows.count
                    workspace.columns[colIdx].windows.removeAll { !tileableIDs.contains($0.id) }
                    if workspace.columns[colIdx].windows.count < before { changed = true; membershipChanged = true }
                    if workspace.columns[colIdx].windows.isEmpty {
                        workspace.columns.remove(at: colIdx)
                        changed = true
                        membershipChanged = true
                    }
                }
                if workspace.focusedColumnIndex >= workspace.columns.count && !workspace.columns.isEmpty {
                    workspace.focusedColumnIndex = workspace.columns.count - 1
                }
                if changed {
                    screenState.workspaces[wsID] = workspace
                }
            }
            state.screens[screenID] = screenState
        }

        // Add new windows
        let existingIDs = Set(state.screens.values.flatMap { $0.workspaces.values.flatMap { $0.columns.flatMap { $0.windows.map { $0.id } } } })
        for wid in tileableIDs {
            guard !existingIDs.contains(wid) else { continue }
            guard let (pid, title) = windowInfo[wid] else { continue }
            addWindowToActiveWorkspace(windowID: wid, pid: pid, title: title)
            membershipChanged = true
        }

        if membershipChanged {
            setNeedsRetile()
        }
    }

    private func handleFocusChanged(pid: pid_t, element: AXUIElement) {
        guard let wid = windowStore.windowID(for: element) else { return }
        updateFocus(windowID: wid)
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
        return state.screens[screenID]?.activeWorkspaceID
    }

    public var activeWorkspace: Workspace? {
        guard let screenID = activeScreenID(),
              let screenState = state.screens[screenID] else { return nil }
        return screenState.workspaces[screenState.activeWorkspaceID]
    }

    private func addWindowToActiveWorkspace(windowID: CGWindowID, pid: pid_t, title: String) {
        guard let screenID = activeScreenID(),
              let wsID = activeWorkspaceID(),
              var screenState = state.screens[screenID],
              var workspace = screenState.workspaces[wsID] else { return }

        let node = WindowNode(id: windowID, pid: pid, title: title)

        let column = Column(windows: [node], focusedWindowIndex: 0, widthFraction: layoutConfig.defaultColumnWidth)

        if workspace.columns.isEmpty {
            workspace.columns = [column]
            workspace.focusedColumnIndex = 0
        } else {
            let insertAt = min(workspace.focusedColumnIndex + 1, workspace.columns.count)
            workspace.columns.insert(column, at: insertAt)
            workspace.focusedColumnIndex = insertAt
        }

        screenState.workspaces[wsID] = workspace
        state.screens[screenID] = screenState
        tiler_log("Added window \(windowID) (\(title)) to workspace \(wsID) column \(workspace.focusedColumnIndex)")
    }

    private func removeWindow(windowID: CGWindowID) {
        for (screenID, var screenState) in state.screens {
            for (wsID, var workspace) in screenState.workspaces {
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

                        screenState.workspaces[wsID] = workspace
                        state.screens[screenID] = screenState
                        tiler_log("Removed window \(windowID) from workspace \(wsID)")
                        return
                    }
                }
            }
        }
    }

    private func removeWindowsForPID(_ pid: pid_t) {
        for (screenID, var screenState) in state.screens {
            var screenChanged = false
            for (wsID, var workspace) in screenState.workspaces {
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
                    screenState.workspaces[wsID] = workspace
                    screenChanged = true
                }
            }
            if screenChanged {
                state.screens[screenID] = screenState
            }
        }
    }

    private func updateFocus(windowID: CGWindowID) {
        for (screenID, var screenState) in state.screens {
            for (wsID, var workspace) in screenState.workspaces {
                for (colIdx, var column) in workspace.columns.enumerated() {
                    if let winIdx = column.windows.firstIndex(where: { $0.id == windowID }) {
                        column.focusedWindowIndex = winIdx
                        workspace.columns[colIdx] = column
                        workspace.focusedColumnIndex = colIdx
                        screenState.workspaces[wsID] = workspace
                        state.screens[screenID] = screenState
                        return
                    }
                }
            }
        }
    }

    // MARK: - Action handling

    public func handleAction(_ action: Action) {
        switch action {

        case .focusColumnLeft:
            guard let screenID = activeScreenID(),
                  let wsID = activeWorkspaceID(),
                  var screenState = state.screens[screenID],
                  var workspace = screenState.workspaces[wsID],
                  workspace.focusedColumnIndex > 0 else { return }
            workspace.focusedColumnIndex -= 1
            screenState.workspaces[wsID] = workspace
            state.screens[screenID] = screenState
            focusFocusedWindow(in: workspace)
            setNeedsRetile()

        case .focusColumnRight:
            guard let screenID = activeScreenID(),
                  let wsID = activeWorkspaceID(),
                  var screenState = state.screens[screenID],
                  var workspace = screenState.workspaces[wsID],
                  workspace.focusedColumnIndex < workspace.columns.count - 1 else { return }
            workspace.focusedColumnIndex += 1
            screenState.workspaces[wsID] = workspace
            state.screens[screenID] = screenState
            focusFocusedWindow(in: workspace)
            setNeedsRetile()

        case .moveColumnLeft:
            guard let screenID = activeScreenID(),
                  let wsID = activeWorkspaceID(),
                  var screenState = state.screens[screenID],
                  var workspace = screenState.workspaces[wsID],
                  workspace.focusedColumnIndex > 0 else { return }
            let idx = workspace.focusedColumnIndex
            workspace.columns.swapAt(idx, idx - 1)
            workspace.focusedColumnIndex -= 1
            screenState.workspaces[wsID] = workspace
            state.screens[screenID] = screenState
            setNeedsRetile()

        case .moveColumnRight:
            guard let screenID = activeScreenID(),
                  let wsID = activeWorkspaceID(),
                  var screenState = state.screens[screenID],
                  var workspace = screenState.workspaces[wsID],
                  workspace.focusedColumnIndex < workspace.columns.count - 1 else { return }
            let idx = workspace.focusedColumnIndex
            workspace.columns.swapAt(idx, idx + 1)
            workspace.focusedColumnIndex += 1
            screenState.workspaces[wsID] = workspace
            state.screens[screenID] = screenState
            setNeedsRetile()

        case .focusWindowUp:
            guard let screenID = activeScreenID(),
                  let wsID = activeWorkspaceID(),
                  var screenState = state.screens[screenID],
                  var workspace = screenState.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            var col = workspace.columns[workspace.focusedColumnIndex]
            guard col.focusedWindowIndex > 0 else { return }
            col.focusedWindowIndex -= 1
            workspace.columns[workspace.focusedColumnIndex] = col
            screenState.workspaces[wsID] = workspace
            state.screens[screenID] = screenState
            focusFocusedWindow(in: workspace)
            setNeedsRetile()

        case .focusWindowDown:
            guard let screenID = activeScreenID(),
                  let wsID = activeWorkspaceID(),
                  var screenState = state.screens[screenID],
                  var workspace = screenState.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            var col = workspace.columns[workspace.focusedColumnIndex]
            guard col.focusedWindowIndex < col.windows.count - 1 else { return }
            col.focusedWindowIndex += 1
            workspace.columns[workspace.focusedColumnIndex] = col
            screenState.workspaces[wsID] = workspace
            state.screens[screenID] = screenState
            focusFocusedWindow(in: workspace)
            setNeedsRetile()

        case .moveWindowUp:
            guard let screenID = activeScreenID(),
                  let wsID = activeWorkspaceID(),
                  var screenState = state.screens[screenID],
                  var workspace = screenState.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            var col = workspace.columns[workspace.focusedColumnIndex]
            guard col.focusedWindowIndex > 0 else { return }
            let idx = col.focusedWindowIndex
            col.windows.swapAt(idx, idx - 1)
            col.focusedWindowIndex -= 1
            workspace.columns[workspace.focusedColumnIndex] = col
            screenState.workspaces[wsID] = workspace
            state.screens[screenID] = screenState
            setNeedsRetile()

        case .moveWindowDown:
            guard let screenID = activeScreenID(),
                  let wsID = activeWorkspaceID(),
                  var screenState = state.screens[screenID],
                  var workspace = screenState.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            var col = workspace.columns[workspace.focusedColumnIndex]
            guard col.focusedWindowIndex < col.windows.count - 1 else { return }
            let idx = col.focusedWindowIndex
            col.windows.swapAt(idx, idx + 1)
            col.focusedWindowIndex += 1
            workspace.columns[workspace.focusedColumnIndex] = col
            screenState.workspaces[wsID] = workspace
            state.screens[screenID] = screenState
            setNeedsRetile()

        case .focusWorkspace(let n):
            guard (1...workspaceCount).contains(n) else { return }
            guard let screenID = activeScreenID(),
                  var screenState = state.screens[screenID] else { return }
            let oldWSID = screenState.activeWorkspaceID
            guard oldWSID != n else { return }
            screenState.activeWorkspaceID = n
            state.screens[screenID] = screenState
            setNeedsRetile()
            if let newWorkspace = screenState.workspaces[n] {
                focusFocusedWindow(in: newWorkspace)
            }
            tiler_log("Switched to workspace \(n)")

        case .moveToWorkspace(let n):
            guard (1...workspaceCount).contains(n) else { return }
            guard let screenID = activeScreenID(),
                  var screenState = state.screens[screenID] else { return }
            let currentWSID = screenState.activeWorkspaceID
            guard currentWSID != n else { return }
            guard var sourceWorkspace = screenState.workspaces[currentWSID],
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
            screenState.workspaces[currentWSID] = sourceWorkspace

            // Add the window to the target workspace
            guard var targetWorkspace = screenState.workspaces[n] else { return }
            let newCol = Column(windows: [window], focusedWindowIndex: 0, widthFraction: layoutConfig.defaultColumnWidth)
            if targetWorkspace.columns.isEmpty {
                targetWorkspace.columns = [newCol]
                targetWorkspace.focusedColumnIndex = 0
            } else {
                let insertAt = min(targetWorkspace.focusedColumnIndex + 1, targetWorkspace.columns.count)
                targetWorkspace.columns.insert(newCol, at: insertAt)
                targetWorkspace.focusedColumnIndex = insertAt
            }
            screenState.workspaces[n] = targetWorkspace
            state.screens[screenID] = screenState

            setNeedsRetile()
            tiler_log("Moved window to workspace \(n)")

        case .increaseColumnWidth:
            guard let screenID = activeScreenID(),
                  let wsID = activeWorkspaceID(),
                  var screenState = state.screens[screenID],
                  var workspace = screenState.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            var col = workspace.columns[workspace.focusedColumnIndex]
            col.widthFraction = min(col.widthFraction + 0.05, 0.8)
            workspace.columns[workspace.focusedColumnIndex] = col
            screenState.workspaces[wsID] = workspace
            state.screens[screenID] = screenState
            setNeedsRetile()

        case .decreaseColumnWidth:
            guard let screenID = activeScreenID(),
                  let wsID = activeWorkspaceID(),
                  var screenState = state.screens[screenID],
                  var workspace = screenState.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            var col = workspace.columns[workspace.focusedColumnIndex]
            col.widthFraction = max(col.widthFraction - 0.05, 0.2)
            workspace.columns[workspace.focusedColumnIndex] = col
            screenState.workspaces[wsID] = workspace
            state.screens[screenID] = screenState
            setNeedsRetile()

        case .toggleColumnTabbed:
            guard let screenID = activeScreenID(),
                  let wsID = activeWorkspaceID(),
                  var screenState = state.screens[screenID],
                  var workspace = screenState.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            var col = workspace.columns[workspace.focusedColumnIndex]
            col.mode = (col.mode == .stack) ? .tab : .stack
            workspace.columns[workspace.focusedColumnIndex] = col
            screenState.workspaces[wsID] = workspace
            state.screens[screenID] = screenState
            setNeedsRetile()

        case .closeWindow:
            guard let wsID = activeWorkspaceID(),
                  let screenID = activeScreenID(),
                  let screenState = state.screens[screenID],
                  let workspace = screenState.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            let col = workspace.columns[workspace.focusedColumnIndex]
            guard col.focusedWindowIndex < col.windows.count else { return }
            let window = col.windows[col.focusedWindowIndex]
            guard let element = windowStore.element(for: window.id) else { return }
            var closeButton: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton)
            if let btn = closeButton {
                AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
            }
            // Window removal will be handled by the .windowDestroyed event

        case .toggleFullscreen:
            guard let wsID = activeWorkspaceID(),
                  let screenID = activeScreenID(),
                  let screenState = state.screens[screenID],
                  let workspace = screenState.workspaces[wsID],
                  !workspace.columns.isEmpty else { return }
            let col = workspace.columns[workspace.focusedColumnIndex]
            guard col.focusedWindowIndex < col.windows.count else { return }
            let window = col.windows[col.focusedWindowIndex]
            guard let element = windowStore.element(for: window.id) else { return }
            var fullscreen: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, "AXFullscreen" as CFString, &fullscreen)
            if result == .success, let isFullscreen = fullscreen as? Bool {
                AXUIElementSetAttributeValue(element, "AXFullscreen" as CFString, !isFullscreen as CFTypeRef)
                tiler_log("Toggled fullscreen on window \(window.id)")
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
        guard let element = windowStore.element(for: window.id) else { return }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, true as CFTypeRef)
    }

    // MARK: - Workspace-specific tiling

    private func screenIDForWorkspace(_ wsID: WorkspaceID) -> ScreenID? {
        return state.screens.first(where: { $0.value.activeWorkspaceID == wsID })?.key
    }

    private func retileWorkspace(_ wsID: WorkspaceID) {
        guard let screenID = screenIDForWorkspace(wsID),
              let screenState = state.screens[screenID],
              let workspace = screenState.workspaces[wsID] else {
            hideWorkspace(wsID)
            return
        }

        let screen = screenState.info
        let offset = ViewportCalc.computeOffset(workspace: workspace, screen: screen, gaps: gaps)
        let frames = LayoutEngine.layout(workspace: workspace, screen: screen, gaps: gaps, viewportOffset: offset)
        AXWindowBridge.applyFrames(frames, store: windowStore)

        if !frames.isEmpty {
            tiler_log("Laid out \(frames.count) windows on workspace \(wsID)")
        }
    }

    private func hideWorkspace(_ wsID: WorkspaceID) {
        for (_, screenState) in state.screens {
            guard let workspace = screenState.workspaces[wsID] else { continue }
            var frames: [CGWindowID: NSRect] = [:]
            for column in workspace.columns {
                for window in column.windows {
                    frames[window.id] = NSRect(x: -100000, y: 0, width: 100, height: 100)
                }
            }
            if !frames.isEmpty {
                AXWindowBridge.applyFrames(frames, store: windowStore)
            }
            return
        }
    }

    private func retileAll() {
        guard let activeWSID = activeWorkspaceID() else { return }
        retileWorkspace(activeWSID)
        // Hide all other active workspaces across screens
        for (screenID, screenState) in state.screens {
            for wsID in screenState.workspaces.keys where wsID != activeWSID || screenID != activeScreenID() {
                hideWorkspace(wsID)
            }
        }
    }

    // MARK: - Layout

    private func retileActiveWorkspace() {
        guard let wsID = activeWorkspaceID(),
              let screenID = activeScreenID(),
              let screenState = state.screens[screenID],
              let workspace = screenState.workspaces[wsID] else {
            return
        }

        let screen = screenState.info
        let offset = ViewportCalc.computeOffset(workspace: workspace, screen: screen, gaps: gaps)
        let frames = LayoutEngine.layout(workspace: workspace, screen: screen, gaps: gaps, viewportOffset: offset)

        AXWindowBridge.applyFrames(frames, store: windowStore)

        if !frames.isEmpty {
            tiler_log("Laid out \(frames.count) windows on workspace \(wsID)")
        }
    }
}
