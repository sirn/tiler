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

    // Epoch-based echo suppression: each retile bumps the epoch and records desired frames
    private struct ApplyRecord { var epoch: UInt64; var frame: NSRect }
    private var applyEpoch: UInt64 = 0
    private var applyRecords: [CGWindowID: ApplyRecord] = [:]
    private var correctionCounts: [CGWindowID: Int] = [:]
    private var moveSettleToken: UInt64 = 0
    private var missingCounts: [CGWindowID: Int] = [:]

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
        // Trigger initial reconcile to discover existing windows
        setNeedsReconcile()
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
        if needsRetile {
            needsRetile = false
            retileActiveWorkspace()
        }
        if needsReconcile {
            needsReconcile = false
            reconcile()
        }
        reconcilePendingFrames()
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
        case .geometryChanged(_, let element):
            guard let wid = windowStore.windowID(for: element) else { return }
            // If the observed frame matches what we applied, it's an echo — ignore it
            if let record = applyRecords[wid],
               let observed = AXWindowBridge.currentFrame(for: element),
               AXWindowBridge.framesMatch(observed, record.frame, tolerance: 2.0) {
                return
            }
            // Genuine user move/resize — debounce so snap-back fires after the user releases
            moveSettleToken &+= 1
            let token = moveSettleToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self, self.moveSettleToken == token else { return }
                self.setNeedsRetile()
            }
        }
    }

    public func reconcile() {
        // Compute the set of pids currently managed in state so parked windows remain reachable
        let managedPIDs = Set(state.screens.values
            .flatMap { $0.workspaces.values }
            .flatMap { $0.columns }
            .flatMap { $0.windows }
            .map { $0.pid })
        windowStore.refresh(managedPIDs: managedPIDs)

        // Build tileable set from CGWindowList + WindowStore
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            tiler_log("reconcile: Could not get window list")
            return
        }

        var tileableIDs: Set<CGWindowID> = []
        var windowInfo: [CGWindowID: (pid: pid_t, title: String)] = [:]
        var skippedNoElement = 0
        var skippedNotTileable = 0
        var totalCandidates = 0

        for info in windowList {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer <= 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }

            totalCandidates += 1
            let title = info[kCGWindowName as String] as? String ?? ""
            windowInfo[wid] = (pid, title)

            if let element = windowStore.element(for: wid) {
                if WindowFilter.isTileable(element) {
                    tileableIDs.insert(wid)
                } else {
                    skippedNotTileable += 1
                    tiler_debug("reconcile: skip not-tileable wid=\(wid) title='\(title)' pid=\(pid)")
                }
            } else {
                skippedNoElement += 1
                tiler_debug("reconcile: skip no-element wid=\(wid) title='\(title)' pid=\(pid)")
            }
        }

        tiler_debug("reconcile: \(totalCandidates) candidates, \(tileableIDs.count) tileable, \(skippedNoElement) no element, \(skippedNotTileable) not tileable")

        // A managed window survives reconcile iff it is currently a tileable AX window:
        // its element is retrievable from the store AND WindowFilter.isTileable returns true.
        // This correctly keeps off-screen-parked windows (not minimized/fullscreen, so still
        // tileable even when absent from the on-screen CGWindowList), while dropping minimized
        // windows (isTileable == false), fullscreen windows (isTileable == false), and
        // destroyed/terminated windows (element == nil after refresh).
        let stillAlive: Set<CGWindowID> = Set(
            state.screens.values
                .flatMap { $0.workspaces.values }
                .flatMap { $0.columns }
                .flatMap { $0.windows }
                .compactMap { window -> CGWindowID? in
                    guard let element = windowStore.element(for: window.id),
                          WindowFilter.isTileable(element) else { return nil }
                    return window.id
                }
        )

        // Compute the set of all managed window ids before any removal.
        let managedIDs = Set(state.screens.values
            .flatMap { $0.workspaces.values }
            .flatMap { $0.columns }
            .flatMap { $0.windows }
            .map { $0.id })

        // Debounced reaping: a window must be missing across two consecutive reconciles before
        // it is removed. This guards against transient AX read misses under load where
        // kAXWindowsAttribute briefly returns fewer windows than actually exist.
        var toReap: Set<CGWindowID> = []
        for id in managedIDs {
            if stillAlive.contains(id) {
                missingCounts[id] = 0
            } else {
                missingCounts[id, default: 0] += 1
                if missingCounts[id]! >= 2 {
                    toReap.insert(id)
                }
            }
        }
        // Prune entries for ids no longer in state (already removed in a prior reconcile).
        missingCounts = missingCounts.filter { managedIDs.contains($0.key) }

        // Remove windows that have been consistently missing (destroyed, minimized, fullscreen).
        // Off-screen-parked windows remain in stillAlive and are preserved.
        var membershipChanged = false
        for (screenID, var screenState) in state.screens {
            for (wsID, var workspace) in screenState.workspaces {
                var changed = false
                for colIdx in workspace.columns.indices.reversed() {
                    let before = workspace.columns[colIdx].windows.count
                    workspace.columns[colIdx].windows.removeAll { toReap.contains($0.id) }
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

        // If any window is on its first miss (not yet reaped), schedule another reconcile so
        // a genuinely-closed window gets its second strike promptly.
        let hasPendingMiss = missingCounts.values.contains { $0 == 1 }
        if hasPendingMiss {
            setNeedsReconcile()
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

        // Prune applyRecords for windows no longer in state
        let liveIDs = Set(state.screens.values.flatMap { $0.workspaces.values }.flatMap { $0.columns }.flatMap { $0.windows }.map { $0.id })
        applyRecords = applyRecords.filter { liveIDs.contains($0.key) }
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
                        applyRecords.removeValue(forKey: windowID)
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
                for colIdx in workspace.columns.indices.reversed() {
                    let before = workspace.columns[colIdx].windows.count
                    let removedWIDs = workspace.columns[colIdx].windows.filter { $0.pid == pid }.map { $0.id }
                    workspace.columns[colIdx].windows.removeAll { $0.pid == pid }
                    if workspace.columns[colIdx].windows.count < before {
                        changed = true
                        for wid in removedWIDs { applyRecords.removeValue(forKey: wid) }
                    }
                    if workspace.columns[colIdx].windows.isEmpty {
                        workspace.columns.remove(at: colIdx)
                        changed = true
                    }
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
            // User explicitly chose width — clear any auto-absorbed minimum
            col.measuredMinWidth = nil
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
            // User explicitly chose width — clear any auto-absorbed minimum
            col.measuredMinWidth = nil
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

        // Raise the window
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        // Set as key window
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, true as CFTypeRef)

        // Activate the app to ensure keyboard focus follows
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    // MARK: - Workspace-specific tiling

    private func screenIDForWorkspace(_ wsID: WorkspaceID) -> ScreenID? {
        return state.screens.first(where: { $0.value.activeWorkspaceID == wsID })?.key
    }

    private func retileWorkspace(_ wsID: WorkspaceID) {
        guard let screenID = screenIDForWorkspace(wsID),
              var screenState = state.screens[screenID],
              var workspace = screenState.workspaces[wsID] else {
            hideWorkspace(wsID)
            return
        }
        let context = LayoutContext(screen: screenState.info, gaps: gaps)
        let output = LayoutResolver.resolve(workspace, context)
        workspace.scrollOffset = output.offset
        screenState.workspaces[wsID] = workspace
        state.screens[screenID] = screenState
        applyEpoch &+= 1
        correctionCounts.removeAll()
        for (wid, frame) in output.frames { applyRecords[wid] = ApplyRecord(epoch: applyEpoch, frame: frame) }
        AXWindowBridge.applyFrames(output.frames, store: windowStore)
        if !output.frames.isEmpty {
            tiler_debug("Laid out \(output.frames.count) windows on workspace \(wsID)")
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
                for (wid, frame) in frames { applyRecords[wid] = ApplyRecord(epoch: applyEpoch, frame: frame) }
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
              var screenState = state.screens[screenID],
              var workspace = screenState.workspaces[wsID] else {
            return
        }
        let context = LayoutContext(screen: screenState.info, gaps: gaps)
        let output = LayoutResolver.resolve(workspace, context)
        workspace.scrollOffset = output.offset
        screenState.workspaces[wsID] = workspace
        state.screens[screenID] = screenState
        applyEpoch &+= 1
        correctionCounts.removeAll()
        for (wid, frame) in output.frames { applyRecords[wid] = ApplyRecord(epoch: applyEpoch, frame: frame) }
        AXWindowBridge.applyFrames(output.frames, store: windowStore)
        if !output.frames.isEmpty {
            tiler_debug("Laid out \(output.frames.count) windows on workspace \(wsID)")
        }
    }

    // MARK: - Corrector

    /// Re-issue frames for windows that haven't reached their desired geometry yet.
    /// Runs once per drain cycle; convergence is driven by incoming AX resize notifications.
    private func reconcilePendingFrames() {
        guard let wsID = activeWorkspaceID(),
              let screenID = activeScreenID(),
              let screenState = state.screens[screenID],
              let workspace = screenState.workspaces[wsID] else { return }

        let liveWIDs = Set(workspace.columns.flatMap { $0.windows }.map { $0.id })

        for (wid, record) in applyRecords where record.epoch == applyEpoch && liveWIDs.contains(wid) {
            guard let element = windowStore.element(for: wid) else { continue }
            guard let observed = AXWindowBridge.currentFrame(for: element) else { continue }

            if AXWindowBridge.framesMatch(observed, record.frame, tolerance: 2.0) {
                correctionCounts.removeValue(forKey: wid)
            } else if correctionCounts[wid, default: 0] < 3 {
                AXWindowBridge.applyFrames([wid: record.frame], store: windowStore)
                correctionCounts[wid, default: 0] += 1
            } else {
                // Budget exhausted: the window won't reach the exact frame (min-size or
                // character-cell quantization). If it's wider than desired, absorb that into
                // the column width; otherwise accept its actual settled frame as the echo
                // reference so future geometry events at this position are treated as echoes
                // (prevents the snap-back path from looping on quantized windows).
                if observed.width > record.frame.width + 2.0 {
                    absorbMinWidth(wid: wid, observedWidth: observed.width)
                } else {
                    applyRecords[wid] = ApplyRecord(epoch: applyEpoch, frame: observed)
                }
            }
        }
    }

    // MARK: - Min-width absorption

    /// Record that a window resisted being narrower than observedWidth, and retile to accommodate.
    private func absorbMinWidth(wid: CGWindowID, observedWidth: CGFloat) {
        guard let screenID = activeScreenID(),
              let wsID = activeWorkspaceID(),
              var screenState = state.screens[screenID],
              var workspace = screenState.workspaces[wsID] else { return }

        for colIdx in workspace.columns.indices {
            if workspace.columns[colIdx].windows.contains(where: { $0.id == wid }) {
                workspace.columns[colIdx].measuredMinWidth = max(
                    workspace.columns[colIdx].measuredMinWidth ?? 0, observedWidth)
                screenState.workspaces[wsID] = workspace
                state.screens[screenID] = screenState
                setNeedsRetile()
                tiler_debug("Absorbed min-width \(observedWidth) for wid=\(wid) in col \(colIdx)")
                return
            }
        }
    }
}
