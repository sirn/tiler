import AppKit
import ApplicationServices
import CoreGraphics

/// Snapshot for the menu bar workspace indicator.
public struct WorkspaceIndicator: Equatable {
  /// Workspace ids with at least one window (always including `current`), ascending.
  public let occupied: [WorkspaceID]
  /// The active workspace id.
  public let current: WorkspaceID

  public init(occupied: [WorkspaceID], current: WorkspaceID) {
    self.occupied = occupied
    self.current = current
  }
}

/// Owns the tiling state and orchestrates the event→layout→apply pipeline.
public class WindowManager {
  public var state: TilerState
  public var gaps: GapConfig
  public var workspaceCount: Int
  public var layoutConfig: LayoutConfig
  public var appRules: [AppRuleConfig]

  public let windowStore = WindowStore()

  /// Fired whenever the menu bar indicator state (occupied workspaces or current) changes.
  public var onWorkspaceIndicatorChanged: ((WorkspaceIndicator) -> Void)?
  private var lastIndicator: WorkspaceIndicator?

  private let eventBroker: EventBroker

  // Coalescing flags
  private var needsReconcile = false
  private var needsRetile = false
  private var drainScheduled = false

  // Convergence model:
  // Each retile bumps applyEpoch and records a desired frame per window in appliedWindows.
  // Incoming AX geometry events are treated as echoes when they match the recorded frame,
  // otherwise as genuine user moves which trigger a debounced snap-back retile.
  // A bounded corrector re-issues frames until they converge or are accepted, tracking the
  // attempt count in the corrections field; apps with minimum-size or character-cell-quantized
  // windows will settle at their nearest achievable geometry rather than the exact requested frame.
  // Window reaping is debounced via missingCounts across reconcile cycles to tolerate transient
  // AX read misses where kAXWindowsAttribute briefly returns fewer windows than actually exist.
  private struct AppliedWindow {
    var epoch: UInt64
    var frame: NSRect
    var corrections: Int = 0
  }
  private var applyEpoch: UInt64 = 0
  private var nextGroupToken: UInt64 = 0
  private func mintGroupKey() -> GroupKey {
    nextGroupToken &+= 1
    return GroupKey(value: nextGroupToken)
  }
  private var appliedWindows: [CGWindowID: AppliedWindow] = [:]
  private var moveSettleToken: UInt64 = 0
  private var missingCounts: [CGWindowID: Int] = [:]
  private var resolveCounts: [CGWindowID: Int] = [:]
  private var resolveRetryToken: UInt64 = 0

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
      hideInactiveWorkspaces()
    }
    if needsReconcile {
      needsReconcile = false
      reconcile()
    }
    reconcilePendingFrames()
    emitWorkspaceIndicatorIfChanged()
  }

  /// Current indicator state for the active screen: workspaces with at least one window
  /// (always including the active workspace), sorted ascending, plus the active workspace.
  public func workspaceIndicator() -> WorkspaceIndicator? {
    guard let screenID = activeScreenID(), let screenState = state.screens[screenID] else {
      return nil
    }
    let current = screenState.activeWorkspaceID
    var occupied = screenState.workspaces
      .filter { _, ws in ws.columns.contains { !$0.windows.isEmpty } }
      .map { $0.key }
    if !occupied.contains(current) { occupied.append(current) }
    occupied.sort()
    return WorkspaceIndicator(occupied: occupied, current: current)
  }

  private func emitWorkspaceIndicatorIfChanged() {
    guard let indicator = workspaceIndicator() else { return }
    if indicator == lastIndicator { return }
    lastIndicator = indicator
    onWorkspaceIndicatorChanged?(indicator)
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
                  target.columns = [
                    Column(
                      windows: [window], focusedWindowIndex: 0,
                      widthFraction: layoutConfig.defaultColumnWidth)
                  ]
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
      let decision: EchoDecision
      if let observed = AXWindowBridge.currentFrame(for: element) {
        decision = classifyGeometryChange(
          observed: observed, applied: appliedWindows[wid]?.frame, tolerance: 2.0)
      } else {
        decision = .genuineMove
      }
      switch decision {
      case .echo:
        return
      case .genuineMove:
        // Genuine user move/resize — debounce so snap-back fires after the user releases
        moveSettleToken &+= 1
        let token = moveSettleToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
          guard let self = self, self.moveSettleToken == token else { return }
          self.setNeedsRetile()
        }
      }
    }
  }

  public func reconcile() {
    // Compute the set of pids currently managed in state so parked windows remain reachable
    let managedPIDs = Set(
      state.screens.values
        .flatMap { $0.workspaces.values }
        .flatMap { $0.columns }
        .flatMap { $0.windows }
        .map { $0.pid })
    windowStore.refresh(managedPIDs: managedPIDs)

    // Build tileable set from CGWindowList + WindowStore
    guard
      let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else {
      tiler_log("reconcile: Could not get window list")
      return
    }

    var tileableIDs: Set<CGWindowID> = []
    var unresolvedCandidates: Set<CGWindowID> = []
    var windowInfo: [CGWindowID: (pid: pid_t, title: String, bounds: NSRect)] = [:]
    var skippedNoElement = 0
    var skippedNotTileable = 0
    var totalCandidates = 0

    for info in windowList {
      guard let wid = info[kCGWindowNumber as String] as? CGWindowID else { continue }
      guard let layer = info[kCGWindowLayer as String] as? Int, layer <= 0 else { continue }
      guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
      guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular
      else { continue }

      totalCandidates += 1
      let title = info[kCGWindowName as String] as? String ?? ""
      let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
      let bounds = NSRect(
        x: boundsDict?["X"] ?? 0, y: boundsDict?["Y"] ?? 0,
        width: boundsDict?["Width"] ?? 0, height: boundsDict?["Height"] ?? 0)
      windowInfo[wid] = (pid, title, bounds)

      if let element = windowStore.element(for: wid) {
        if WindowFilter.isTileable(element) {
          tileableIDs.insert(wid)
        } else {
          skippedNotTileable += 1
          unresolvedCandidates.insert(wid)
          tiler_debug("reconcile: skip not-tileable wid=\(wid) title='\(title)' pid=\(pid)")
        }
      } else {
        skippedNoElement += 1
        unresolvedCandidates.insert(wid)
        tiler_debug("reconcile: skip no-element wid=\(wid) title='\(title)' pid=\(pid)")
      }
    }

    tiler_debug(
      "reconcile: \(totalCandidates) candidates, \(tileableIDs.count) tileable, \(skippedNoElement) no element, \(skippedNotTileable) not tileable"
    )

    // A managed window survives reconcile iff it is a tileable AX window AND it is either
    // present in the on-screen CGWindowList or one we deliberately parked off-screen. A
    // native background tab (in apps that keep every tab in the AX window list) is
    // AX-tileable and resolvable but absent from the on-screen list; if its column sits in
    // the visible area it renders as an invisible, unfocusable gap. We detect that by the
    // window being absent from the on-screen list while its applied frame substantially
    // overlaps the visible area, and drop it (debounced via missingCounts) so the tab group
    // collapses back to its single visible tab. Windows we parked off-screen overlap the
    // visible area by at most the ~1px edge sliver, so they are kept. Minimized / fullscreen
    // (isTileable == false) and destroyed (element == nil) windows remain dropped.
    let onScreenIDs = Set(windowInfo.keys)
    var stillAlive: Set<CGWindowID> = []
    for screenState in state.screens.values {
      let visibleFrame = screenState.info.visibleFrame
      for workspace in screenState.workspaces.values {
        for column in workspace.columns {
          for window in column.windows {
            guard let element = windowStore.element(for: window.id),
              WindowFilter.isTileable(element)
            else { continue }
            if onScreenIDs.contains(window.id) {
              stillAlive.insert(window.id)
              continue
            }
            // Absent from the on-screen list. Keep it if it has no applied frame yet (just
            // added, not laid out) or if that frame is essentially off-screen (we parked
            // it); otherwise it is expected-visible but unrendered — a background tab.
            guard let frame = appliedWindows[window.id]?.frame else {
              stillAlive.insert(window.id)
              continue
            }
            let overlap =
              min(frame.maxX, visibleFrame.maxX) - max(frame.minX, visibleFrame.minX)
            if overlap <= 50 {
              stillAlive.insert(window.id)
            } else {
              tiler_debug(
                "reconcile: background-tab drop wid=\(window.id) pid=\(window.pid) overlap=\(Int(overlap)) (absent from on-screen list)")
            }
          }
        }
      }
    }

    // Compute the set of all managed window ids before any removal.
    let managedIDs = Set(
      state.screens.values
        .flatMap { $0.workspaces.values }
        .flatMap { $0.columns }
        .flatMap { $0.windows }
        .map { $0.id })

    let plan = reconcilePlan(
      managedIDs: managedIDs,
      stillAliveIDs: stillAlive,
      tileableIDs: tileableIDs,
      missingCounts: missingCounts,
      missThreshold: 2,
      unresolvedIDs: unresolvedCandidates.subtracting(managedIDs),
      resolveCounts: resolveCounts,
      resolveThreshold: 8)
    missingCounts = plan.updatedMissingCounts
    resolveCounts = plan.updatedResolveCounts
    tiler_debug(
      "reconcile: tileable=\(tileableIDs.sorted()) managed=\(managedIDs.sorted()) stillAlive=\(stillAlive.sorted()) toAdd=\(plan.toAdd.sorted()) toReap=\(plan.toReap.sorted())")

    // Tab-correlation pass: when a native macOS tab switch happens, the previously-active tab
    // window drops out of kAXWindowsAttribute (making it vanish from stillAlive) and a new
    // CGWindowID appears at the same frame and pid. Without this pass, the old tile would be
    // reaped and the new id inserted as a fresh column, jumbling the layout.
    //
    // We correlate each incoming new id against managed windows by (pid, frame) proximity,
    // then either swap the id in-place (the old backing window is gone) or suppress the add
    // entirely (the old backing window is still live — event-ordering lag or sibling tab).
    var adjustedToAdd = plan.toAdd
    var tabSwaps: [CGWindowID: CGWindowID] = [:]  // old -> new

    if let activeScr = activeScreenID(), let activeWS = activeWorkspaceID(),
      let activeManagedState = state.screens[activeScr]?.workspaces[activeWS]
    {
      // Collect managed windows in the active workspace with their applied frames.
      let managedInActiveWS: [(id: CGWindowID, pid: pid_t, applied: NSRect)] =
        activeManagedState.columns
        .flatMap { $0.windows }
        .compactMap { win -> (id: CGWindowID, pid: pid_t, applied: NSRect)? in
          guard let frame = appliedWindows[win.id]?.frame else { return nil }
          return (win.id, win.pid, frame)
        }

      let vanished = Set(managedInActiveWS.map { $0.id }).subtracting(stillAlive)
      var consumed: Set<CGWindowID> = []

      // The new window's CGWindowList bounds are top-left origin; managed tiles' applied
      // frames are Cocoa bottom-left. Convert before matching so all four edges (including
      // Y) are comparable — Y is essential to tell vertically-stacked same-pid windows apart.
      let screenHeight =
        NSScreen.screens.first?.frame.height ?? CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))

      for newID in adjustedToAdd.sorted() {
        guard let info = windowInfo[newID] else { continue }
        let cocoaBounds = NSRect(
          x: info.bounds.minX,
          y: screenHeight - info.bounds.minY - info.bounds.height,
          width: info.bounds.width,
          height: info.bounds.height)

        let candidates = managedInActiveWS.filter { v in
          v.pid == info.pid && !consumed.contains(v.id)
            && framesMatch(cocoaBounds, v.applied, tolerance: 10)
        }
        // Only correlate on an unambiguous match. Zero or multiple same-pid tiles at this
        // frame (e.g. several columns parked at the same off-screen edge) are ambiguous, so
        // leave the new window to be added as its own column rather than risk swapping the
        // wrong tile. A spurious column self-heals on a later reconcile; a wrong swap is
        // silent, permanent corruption.
        guard candidates.count == 1, let match = candidates.first else { continue }

        if vanished.contains(match.id) {
          // Case A: the managed window for this frame left — adopt the new active id in-place.
          tabSwaps[match.id] = newID
          consumed.insert(match.id)
          adjustedToAdd.remove(newID)
          tiler_debug("Native tab swap: wid \(match.id) -> \(newID)")
        } else {
          // Case B: the managed window still backs this tile; suppress the redundant sibling.
          adjustedToAdd.remove(newID)
          tiler_debug("Native tab sibling suppressed: wid \(newID) (live tile \(match.id))")
        }
      }
    }

    // Apply tab swaps: replace old ids in-place so the tile keeps its column position.
    for (oldID, newID) in tabSwaps {
      guard let info = windowInfo[newID] else { continue }
      swapWindowID(from: oldID, to: newID, title: info.title)
      if let record = appliedWindows[oldID] {
        appliedWindows[newID] = record
      }
      appliedWindows.removeValue(forKey: oldID)
      missingCounts.removeValue(forKey: oldID)
      resolveCounts.removeValue(forKey: oldID)
    }
    if !tabSwaps.isEmpty {
      setNeedsRetile()
    }

    // Remove windows that have been consistently missing (destroyed, minimized, fullscreen).
    // Off-screen-parked windows remain in stillAlive and are preserved.
    var membershipChanged = false
    for (screenID, var screenState) in state.screens {
      for (wsID, var workspace) in screenState.workspaces {
        var changed = false
        for colIdx in workspace.columns.indices.reversed() {
          let before = workspace.columns[colIdx].windows.count
          let reaped = workspace.columns[colIdx].windows.filter { plan.toReap.contains($0.id) }
          for w in reaped {
            tiler_debug("reconcile: reaping wid=\(w.id) pid=\(w.pid) title='\(w.title)' from ws=\(wsID)")
          }
          workspace.columns[colIdx].windows.removeAll { plan.toReap.contains($0.id) }
          if workspace.columns[colIdx].windows.count < before {
            changed = true
            membershipChanged = true
          }
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
    if plan.hasPendingMiss {
      setNeedsReconcile()
    }

    // Additions counterpart to the removal retry: when a candidate window has no AX element
    // yet (or isn't tileable yet), schedule a delayed reconcile to re-check. The delay gives
    // the AX tree time to map the new window's element. Bounded by resolveThreshold so
    // permanently-unresolvable windows stop retrying after a fixed number of attempts.
    if plan.hasPendingResolve {
      resolveRetryToken &+= 1
      let token = resolveRetryToken
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        guard let self = self, self.resolveRetryToken == token else { return }
        self.setNeedsReconcile()
      }
    }

    // Add new windows
    for wid in adjustedToAdd {
      guard let (pid, title, _) = windowInfo[wid] else { continue }
      addWindowToActiveWorkspace(windowID: wid, pid: pid, title: title)
      membershipChanged = true
    }

    if membershipChanged {
      setNeedsRetile()
    }

    // Prune appliedWindows for windows no longer in state
    let liveIDs = Set(
      state.screens.values.flatMap { $0.workspaces.values }.flatMap { $0.columns }.flatMap {
        $0.windows
      }.map { $0.id })
    appliedWindows = appliedWindows.filter { liveIDs.contains($0.key) }
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
      let screenState = state.screens[screenID]
    else { return nil }
    return screenState.workspaces[screenState.activeWorkspaceID]
  }

  private func addWindowToActiveWorkspace(windowID: CGWindowID, pid: pid_t, title: String) {
    guard let screenID = activeScreenID(),
      let wsID = activeWorkspaceID(),
      var screenState = state.screens[screenID],
      var workspace = screenState.workspaces[wsID]
    else { return }

    let node = WindowNode(id: windowID, groupKey: mintGroupKey(), pid: pid, title: title)

    let column = Column(
      windows: [node], focusedWindowIndex: 0, widthFraction: layoutConfig.defaultColumnWidth)

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
    tiler_log(
      "Added window \(windowID) (\(title)) to workspace \(wsID) column \(workspace.focusedColumnIndex)"
    )
  }

  /// Replace a managed window's id in-place (for native-tab active-window changes).
  /// The new node keeps the old node's position within its column.
  private func swapWindowID(from oldID: CGWindowID, to newID: CGWindowID, title: String) {
    for (screenID, var screenState) in state.screens {
      for (wsID, var workspace) in screenState.workspaces {
        for (colIdx, var column) in workspace.columns.enumerated() {
          if let winIdx = column.windows.firstIndex(where: { $0.id == oldID }) {
            let existing = column.windows[winIdx]
            column.windows[winIdx] = WindowNode(id: newID, groupKey: existing.groupKey, pid: existing.pid, title: title)
            workspace.columns[colIdx] = column
            screenState.workspaces[wsID] = workspace
            state.screens[screenID] = screenState
            return
          }
        }
      }
    }
  }

  private func removeWindow(windowID: CGWindowID) {
    for (screenID, var screenState) in state.screens {
      for (wsID, var workspace) in screenState.workspaces {
        for (colIdx, var column) in workspace.columns.enumerated() {
          if let removeIdx = column.windows.firstIndex(where: { $0.id == windowID }) {
            column.windows.remove(at: removeIdx)

            if column.windows.isEmpty {
              workspace.columns.remove(at: colIdx)
              if workspace.focusedColumnIndex >= workspace.columns.count
                && !workspace.columns.isEmpty
              {
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
            appliedWindows.removeValue(forKey: windowID)
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
            for wid in removedWIDs { appliedWindows.removeValue(forKey: wid) }
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

  /// True when the given window id is tracked by any tile in any workspace.
  private func isManaged(_ wid: CGWindowID) -> Bool {
    for screenState in state.screens.values {
      for workspace in screenState.workspaces.values {
        for column in workspace.columns {
          if column.windows.contains(where: { $0.id == wid }) { return true }
        }
      }
    }
    return false
  }

  // MARK: - Action handling

  public func handleAction(_ action: Action) {
    switch action {

    case .focusColumnLeft:
      guard let screenID = activeScreenID(),
        let wsID = activeWorkspaceID(),
        var screenState = state.screens[screenID],
        var workspace = screenState.workspaces[wsID],
        workspace.focusedColumnIndex > 0
      else { return }
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
        workspace.focusedColumnIndex < workspace.columns.count - 1
      else { return }
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
        workspace.focusedColumnIndex > 0
      else { return }
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
        workspace.focusedColumnIndex < workspace.columns.count - 1
      else { return }
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
        !workspace.columns.isEmpty
      else { return }
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
        !workspace.columns.isEmpty
      else { return }
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
        !workspace.columns.isEmpty
      else { return }
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
        !workspace.columns.isEmpty
      else { return }
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
        var screenState = state.screens[screenID]
      else { return }
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
        var screenState = state.screens[screenID]
      else { return }
      let currentWSID = screenState.activeWorkspaceID
      guard currentWSID != n else { return }
      guard var sourceWorkspace = screenState.workspaces[currentWSID],
        !sourceWorkspace.columns.isEmpty
      else { return }

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
        if sourceWorkspace.focusedColumnIndex >= sourceWorkspace.columns.count
          && !sourceWorkspace.columns.isEmpty
        {
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
      let newCol = Column(
        windows: [window], focusedWindowIndex: 0, widthFraction: layoutConfig.defaultColumnWidth)
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
        !workspace.columns.isEmpty
      else { return }
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
        !workspace.columns.isEmpty
      else { return }
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
        !workspace.columns.isEmpty
      else { return }
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
        !workspace.columns.isEmpty
      else { return }
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
        !workspace.columns.isEmpty
      else { return }
      let col = workspace.columns[workspace.focusedColumnIndex]
      guard col.focusedWindowIndex < col.windows.count else { return }
      let window = col.windows[col.focusedWindowIndex]
      guard let element = windowStore.element(for: window.id) else { return }
      var fullscreen: CFTypeRef?
      let result = AXUIElementCopyAttributeValue(element, "AXFullscreen" as CFString, &fullscreen)
      if result == .success, let isFullscreen = fullscreen as? Bool {
        AXUIElementSetAttributeValue(
          element, "AXFullscreen" as CFString, !isFullscreen as CFTypeRef)
        tiler_log("Toggled fullscreen on window \(window.id)")
      }

    case .consumeOrExpelLeft:
      consumeOrExpelFocused(.left)
    case .consumeOrExpelRight:
      consumeOrExpelFocused(.right)
    }
  }

  private func consumeOrExpelFocused(_ direction: HorizontalDirection) {
    guard let screenID = activeScreenID(), let wsID = activeWorkspaceID(),
      var screenState = state.screens[screenID],
      var workspace = screenState.workspaces[wsID]
    else { return }
    guard let result = consumeOrExpel(
      columns: workspace.columns,
      focusedColumnIndex: workspace.focusedColumnIndex,
      direction: direction)
    else { return }
    workspace.columns = result.columns
    workspace.focusedColumnIndex = result.focusedColumnIndex
    screenState.workspaces[wsID] = workspace
    state.screens[screenID] = screenState
    setNeedsRetile()
  }

  // MARK: - Focus helpers

  private func focusFocusedWindow(in workspace: Workspace) {
    guard !workspace.columns.isEmpty,
      workspace.focusedColumnIndex < workspace.columns.count
    else { return }
    let col = workspace.columns[workspace.focusedColumnIndex]
    guard col.focusedWindowIndex < col.windows.count else { return }
    let window = col.windows[col.focusedWindowIndex]
    tiler_debug(
      "focus: col=\(workspace.focusedColumnIndex) winIdx=\(col.focusedWindowIndex) tile=\(window.id) pid=\(window.pid) tileFrame=\(String(describing: appliedWindows[window.id]?.frame)) storedElement=\(windowStore.element(for: window.id) != nil)")

    var targetElement = windowStore.element(for: window.id)
    var adopted = false

    // A native tab group has exactly one window in the on-screen CGWindowList (background
    // tabs are absent), so the on-screen window matching this tile's frame is the group's
    // currently-active tab. Switching tabs emits no usable notification, so our stored id
    // can be a stale sibling; raising it would force the app back to that tab. Resolve the
    // active tab and adopt its id in place, then raise it (a no-op for tab selection).
    if let tileFrame = appliedWindows[window.id]?.frame,
      let active = currentActiveTab(pid: window.pid, tileFrame: tileFrame, currentID: window.id),
      active.wid != window.id
    {
      swapWindowID(from: window.id, to: active.wid, title: window.title)
      if let record = appliedWindows[window.id] { appliedWindows[active.wid] = record }
      appliedWindows.removeValue(forKey: window.id)
      missingCounts.removeValue(forKey: window.id)
      resolveCounts.removeValue(forKey: window.id)
      targetElement = active.element
      adopted = true
      tiler_debug("focus: tab adopt \(window.id) -> \(active.wid)")
    }

    guard let element = targetElement else {
      tiler_debug("focus: no element for tile=\(window.id) pid=\(window.pid) — fallback raise + reconcile")
      // The stored id is a dead/invisible tab and the active tab couldn't be adopted cleanly
      // (transient mid tab-switch, or it's tracked elsewhere). Fall back to raising whatever
      // on-screen window sits at this tile's frame so focus still lands on the group, then
      // activate the app and reconcile to repair the tile id.
      if let app = NSRunningApplication(processIdentifier: window.pid) {
        app.activate(options: [.activateIgnoringOtherApps])
      }
      if let tileFrame = appliedWindows[window.id]?.frame,
        let fallback = windowAtFrame(pid: window.pid, frame: tileFrame)
      {
        AXUIElementSetAttributeValue(fallback, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementPerformAction(fallback, kAXRaiseAction as CFString)
      }
      setNeedsReconcile()
      return
    }

    // Activate the app first so bringing it to the front does not re-focus its previous
    // main window; then make this window main and raise it last so it ends up key.
    if let app = NSRunningApplication(processIdentifier: window.pid) {
      app.activate(options: [.activateIgnoringOtherApps])
    }
    AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, true as CFTypeRef)
    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    tiler_debug(
      "focus: raised wid=\(window.id) pid=\(window.pid) appFound=\(NSRunningApplication(processIdentifier: window.pid) != nil)")

    // If we raised the stored tile without adopting an active tab, and that tile is absent
    // from the on-screen CGWindowList while we expect it visible (its applied frame
    // substantially overlaps the visible area), it is a native background tab rendering as
    // an invisible, unfocusable column. Kick a reconcile so the reaper collapses it now
    // rather than on the next window open/close.
    if !adopted,
      let frame = appliedWindows[window.id]?.frame,
      let screenID = activeScreenID(),
      let visibleFrame = state.screens[screenID]?.info.visibleFrame
    {
      let overlap = min(frame.maxX, visibleFrame.maxX) - max(frame.minX, visibleFrame.minX)
      if overlap > 50, !isOnScreen(window.id) {
        tiler_debug("focus: tile=\(window.id) is a visible background tab — kicking reconcile")
        setNeedsReconcile()
      }
    }
  }

  /// The currently-active tab window for a native tab group: the single on-screen
  /// CGWindowList window matching `tileFrame` for `pid` (background tabs are absent from
  /// the on-screen list). CGWindowList bounds are top-left origin; `tileFrame` is Cocoa
  /// bottom-left, so convert before matching — the Y axis disambiguates vertically-stacked
  /// same-pid windows. Adoption is intentionally conservative: it only returns a window
  /// when EXACTLY ONE on-screen window matches the frame and that window is not already a
  /// managed tile. Multiple matches (e.g. several same-app columns parked at the same
  /// off-screen edge) are ambiguous, so we leave the tile unchanged rather than risk
  /// adopting another tile's window.
  private func currentActiveTab(pid: pid_t, tileFrame: NSRect, currentID: CGWindowID)
    -> (wid: CGWindowID, element: AXUIElement)?
  {
    guard
      let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    let screenHeight =
      NSScreen.screens.first?.frame.height ?? CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
    var matches: [CGWindowID] = []
    for info in list {
      guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
        let wid = info[kCGWindowNumber as String] as? CGWindowID,
        let layer = info[kCGWindowLayer as String] as? Int, layer <= 0,
        let b = info[kCGWindowBounds as String] as? [String: CGFloat]
      else { continue }
      let cocoaY = screenHeight - (b["Y"] ?? 0) - (b["Height"] ?? 0)
      let cocoa = NSRect(
        x: b["X"] ?? 0, y: cocoaY, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
      if framesMatch(cocoa, tileFrame, tolerance: 10) {
        matches.append(wid)
      }
    }
    // Only adopt on an unambiguous match to a window not owned by another tile.
    guard matches.count == 1, let activeWid = matches.first,
      activeWid != currentID, !isManaged(activeWid)
    else { return nil }
    guard
      let element = windowStore.element(for: activeWid)
        ?? windowStore.liveElement(forPID: pid, wid: activeWid)
    else { return nil }
    return (activeWid, element)
  }

  /// Best-effort: any on-screen window of `pid` physically located at `frame` (Cocoa
  /// coords), resolved to an AX element. Unlike `currentActiveTab` this applies no
  /// unique/unmanaged guard — it is only used to put focus on a group whose tile id has
  /// gone stale and whose active tab couldn't be adopted cleanly, so raising the wrong
  /// sibling is harmless (it's focus, not an id swap).
  private func windowAtFrame(pid: pid_t, frame: NSRect) -> AXUIElement? {
    guard
      let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    let screenHeight =
      NSScreen.screens.first?.frame.height ?? CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
    for info in list {
      guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
        let wid = info[kCGWindowNumber as String] as? CGWindowID,
        let layer = info[kCGWindowLayer as String] as? Int, layer <= 0,
        let b = info[kCGWindowBounds as String] as? [String: CGFloat]
      else { continue }
      let cocoaY = screenHeight - (b["Y"] ?? 0) - (b["Height"] ?? 0)
      let cocoa = NSRect(
        x: b["X"] ?? 0, y: cocoaY, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
      if framesMatch(cocoa, frame, tolerance: 10) {
        return windowStore.element(for: wid) ?? windowStore.liveElement(forPID: pid, wid: wid)
      }
    }
    return nil
  }

  /// True if `wid` currently appears in the on-screen CGWindowList. A native background tab
  /// does not, even when it remains a resolvable AX window.
  private func isOnScreen(_ wid: CGWindowID) -> Bool {
    guard
      let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return true }
    for info in list {
      if let w = info[kCGWindowNumber as String] as? CGWindowID, w == wid { return true }
    }
    return false
  }

  // MARK: - Workspace-specific tiling

  private func screenIDForWorkspace(_ wsID: WorkspaceID) -> ScreenID? {
    return state.screens.first(where: { $0.value.activeWorkspaceID == wsID })?.key
  }

  private func retileWorkspace(_ wsID: WorkspaceID) {
    guard let screenID = screenIDForWorkspace(wsID),
      var screenState = state.screens[screenID],
      var workspace = screenState.workspaces[wsID]
    else {
      return
    }
    let context = LayoutContext(screen: screenState.info, gaps: gaps)
    let output = LayoutResolver.resolve(workspace, context)
    workspace.scrollOffset = output.offset
    screenState.workspaces[wsID] = workspace
    state.screens[screenID] = screenState
    applyEpoch &+= 1
    for (wid, frame) in output.frames {
      appliedWindows[wid] = AppliedWindow(epoch: applyEpoch, frame: frame)
    }
    AXWindowBridge.applyFrames(output.frames, store: windowStore)
    if !output.frames.isEmpty {
      tiler_debug("Laid out \(output.frames.count) windows on workspace \(wsID)")
    }
  }

  private func hideInactiveWorkspaces() {
    guard let activeScr = activeScreenID(),
      let activeWS = activeWorkspaceID()
    else { return }

    var frames: [CGWindowID: NSRect] = [:]

    for (screenID, screenState) in state.screens {
      let visibleFrame = screenState.info.visibleFrame
      for (wsID, workspace) in screenState.workspaces {
        // Only park windows that are NOT on the active workspace of the active screen
        guard !(screenID == activeScr && wsID == activeWS) else { continue }
        for column in workspace.columns {
          for window in column.windows {
            let wid = window.id
            // Idempotency: already parked if record's minX is left of the visible area
            if let record = appliedWindows[wid], record.frame.minX < visibleFrame.minX {
              continue
            }
            guard let element = windowStore.element(for: wid) else { continue }
            guard let current = AXWindowBridge.currentFrame(for: element) else { continue }
            // Park position-only: right edge lands 1px into visible area, size unchanged
            let parked = NSRect(
              x: visibleFrame.minX - current.width + 1,
              y: current.minY,
              width: current.width,
              height: current.height)
            frames[wid] = parked
          }
        }
      }
    }

    guard !frames.isEmpty else { return }
    // Record before applying so incoming AX events are treated as echoes
    for (wid, parked) in frames {
      appliedWindows[wid] = AppliedWindow(epoch: applyEpoch, frame: parked)
    }
    AXWindowBridge.applyFrames(frames, store: windowStore)
    tiler_debug("Parked \(frames.count) windows from inactive workspaces")
  }

  // MARK: - Layout

  private func retileActiveWorkspace() {
    guard let wsID = activeWorkspaceID(),
      let screenID = activeScreenID(),
      var screenState = state.screens[screenID],
      var workspace = screenState.workspaces[wsID]
    else {
      return
    }
    let context = LayoutContext(screen: screenState.info, gaps: gaps)
    let output = LayoutResolver.resolve(workspace, context)
    workspace.scrollOffset = output.offset
    screenState.workspaces[wsID] = workspace
    state.screens[screenID] = screenState
    applyEpoch &+= 1
    for (wid, frame) in output.frames {
      appliedWindows[wid] = AppliedWindow(epoch: applyEpoch, frame: frame)
    }
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
      let workspace = screenState.workspaces[wsID]
    else { return }

    let liveWIDs = Set(workspace.columns.flatMap { $0.windows }.map { $0.id })

    for (wid, record) in appliedWindows where record.epoch == applyEpoch && liveWIDs.contains(wid) {
      guard let element = windowStore.element(for: wid) else { continue }
      guard let observed = AXWindowBridge.currentFrame(for: element) else { continue }

      if AXWindowBridge.framesMatch(observed, record.frame, tolerance: 2.0) {
        appliedWindows[wid]?.corrections = 0
      } else if (appliedWindows[wid]?.corrections ?? 0) < 3 {
        AXWindowBridge.applyFrames([wid: record.frame], store: windowStore)
        appliedWindows[wid]?.corrections += 1
      } else {
        // Budget exhausted: the window won't reach the exact frame (min-size or
        // character-cell quantization). If it's wider than desired, absorb that into
        // the column width; otherwise accept its actual settled frame as the echo
        // reference so future geometry events at this position are treated as echoes
        // (prevents the snap-back path from looping on quantized windows).
        if observed.width > record.frame.width + 2.0 {
          absorbMinWidth(wid: wid, observedWidth: observed.width)
        } else {
          appliedWindows[wid]?.frame = observed
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
      var workspace = screenState.workspaces[wsID]
    else { return }

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
