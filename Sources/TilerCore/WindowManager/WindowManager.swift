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
  public var minWindowWidth: CGFloat
  public var minWindowHeight: CGFloat

  public let windowStore = WindowStore()
  private var floatingWindows: Set<CGWindowID> = []
  private var appRules: [AppRuleConfig] = []

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
  private func mintGroupKey() -> WindowNode.GroupKey {
    nextGroupToken &+= 1
    return WindowNode.GroupKey(value: nextGroupToken)
  }
  private var appliedWindows: [WindowNode.GroupKey: AppliedWindow] = [:]
  private var moveSettleToken: UInt64 = 0
  private var missingCounts: [CGWindowID: Int] = [:]
  private var resolveCounts: [CGWindowID: Int] = [:]
  private var reapSuppressedUntil: Date?
  private var missPendingToken: UInt64 = 0
  private var resolveRetryToken: UInt64 = 0
  /// Windows whose bounds are still settling after first appearance (e.g. during open animation).
  private var settlingWindows: [CGWindowID: (stableSince: Date, bounds: NSRect)] = [:]
  private var settleRecheckToken: UInt64 = 0
  private let settleDuration: TimeInterval = 0.25
  /// Whether the next reconcile call is the first one after startup.
  /// First reconcile adds windows immediately so restoreState has a windowPool.
  private var isFirstReconcile = true
  private var consumeRefreshToken: UInt64 = 0
  private var hadNoElementLastPass: Bool = false
  /// Window IDs that were not-tileable in the previous reconcile (e.g. fullscreen,
  /// minimized). Used to detect transitions back to tileable so we can reset
  /// stale measuredMinWidth/measuredMinHeight that may have been absorbed during
  /// the non-tileable phase.
  private var wasNotTileableLastPass: Set<CGWindowID> = []
  private let statePersistence = StatePersistence()
  private var needsSave = false
  private var reconcileTimer: Timer?
  private var screenChangeObserver: NSObjectProtocol?
  private var screenLockObserver: NSObjectProtocol?
  private var screenUnlockObserver: NSObjectProtocol?
  private var focusedScreenID: ScreenID?
  private var pendingFocus: (wid: CGWindowID?, element: AXUIElement, pid: pid_t)?
  private var pendingFocusAttempts: Int = 0

  public init(eventBroker: EventBroker, config: Config = Config.defaults) {
    self.state = TilerState()
    self.gaps = GapConfig(
      outerGaps: config.general.outerGaps,
      innerGaps: config.general.innerGaps,
      columnGaps: config.general.columnGaps
    )
    self.workspaceCount = max(1, config.workspaces.count)
    self.layoutConfig = config.layout
    self.minWindowWidth = config.general.minWindowWidth
    self.minWindowHeight = config.general.minWindowHeight
    self.appRules = config.appRules

    self.eventBroker = eventBroker

    eventBroker.onEvent = { [weak self] event in
      self?.handleEvent(event)
    }
    screenChangeObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.reconfigureScreens()
    }
    screenLockObserver = DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("com.apple.screenIsLocked"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.screenDidLock()
    }
    screenUnlockObserver = DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("com.apple.screenIsUnlocked"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.screenDidUnlock()
    }
  }

  deinit {
    if let obs = screenChangeObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    if let obs = screenLockObserver {
      DistributedNotificationCenter.default().removeObserver(obs)
    }
    if let obs = screenUnlockObserver {
      DistributedNotificationCenter.default().removeObserver(obs)
    }
    stop()
  }

  public func start() {
    setNeedsReconcile()
    scheduleDrain()
    reconcileTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      self?.setNeedsReconcile()
    }
  }

  public func stop() {
    reconcileTimer?.invalidate()
    reconcileTimer = nil
    if let obs = screenChangeObserver {
      NotificationCenter.default.removeObserver(obs)
      screenChangeObserver = nil
    }
    if let obs = screenLockObserver {
      DistributedNotificationCenter.default().removeObserver(obs)
      screenLockObserver = nil
    }
    if let obs = screenUnlockObserver {
      DistributedNotificationCenter.default().removeObserver(obs)
      screenUnlockObserver = nil
    }
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
      retileAllScreens()
      hideInactiveWorkspaces()
      writeCrashRecoveryFile()
    }
    if needsReconcile {
      needsReconcile = false
      reconcile()
    }
    reconcilePendingFrames()
    if needsSave {
      needsSave = false
      statePersistence.save(state)
    }
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

  public func restoreState() {
    guard let persisted = statePersistence.load() else { return }

    var windowPool: [CGWindowID: WindowNode] = [:]
    for screenState in state.screens.values {
      for workspace in screenState.workspaces.values {
        for column in workspace.columns {
          for window in column.windows { windowPool[window.id] = window }
        }
      }
    }
    guard !windowPool.isEmpty else { return }

    for screenID in state.screens.keys {
      guard var screenState = state.screens[screenID] else { continue }
      for wsID in screenState.workspaces.keys {
        screenState.workspaces[wsID] = Workspace(id: wsID)
      }
      state.screens[screenID] = screenState
    }

    var placed: Set<CGWindowID> = []

    var unmatchedPersistedKeys: [String] = []  // persisted screens that need position fallback
    var matchedCurrentIDs: Set<ScreenID> = []  // current screens already restored by ID

    for (screenIDStr, persistedScreen) in persisted.screens {
      guard let screenID = UInt32(screenIDStr),
        var screenState = state.screens[screenID]
      else {
        unmatchedPersistedKeys.append(screenIDStr)
        continue
      }
      matchedCurrentIDs.insert(screenID)

      if persistedScreen.activeWorkspaceID >= 1
        && persistedScreen.activeWorkspaceID <= workspaceCount
      {
        screenState.activeWorkspaceID = persistedScreen.activeWorkspaceID
      }

      for (wsIDStr, persistedWS) in persistedScreen.workspaces {
        guard let wsID = Int(wsIDStr),
          wsID >= 1 && wsID <= workspaceCount,
          var workspace = screenState.workspaces[wsID]
        else { continue }

        restoreColumns(from: persistedWS, into: &workspace, windowPool: windowPool, placed: &placed)
        screenState.workspaces[wsID] = workspace
      }

      state.screens[screenID] = screenState
    }

    // Fallback: match persisted screens that had no matching current screen ID
    // by left-to-right position order (handles display ID changes after sleep/lock)
    if !unmatchedPersistedKeys.isEmpty {
      let availableCurrent = state.screens.keys
        .filter { !matchedCurrentIDs.contains($0) }
        .sorted {
          let a = state.screens[$0]?.info.visibleFrame ?? .zero
          let b = state.screens[$1]?.info.visibleFrame ?? .zero
          return a.minX != b.minX ? a.minX < b.minX : a.minY < b.minY
        }
      let orderedUnmatched = unmatchedPersistedKeys.sorted { (UInt32($0) ?? 0) < (UInt32($1) ?? 0) }

      for (pIdx, screenIDStr) in orderedUnmatched.enumerated() {
        guard pIdx < availableCurrent.count else { break }  // stop at bounds; excess become unplaced
        guard let persistedScreen = persisted.screens[screenIDStr] else { continue }
        let targetID = availableCurrent[pIdx]
        guard var screenState = state.screens[targetID] else { continue }

        if persistedScreen.activeWorkspaceID >= 1
          && persistedScreen.activeWorkspaceID <= workspaceCount
        {
          screenState.activeWorkspaceID = persistedScreen.activeWorkspaceID
        }

        for (wsIDStr, persistedWS) in persistedScreen.workspaces {
          guard let wsID = Int(wsIDStr),
            wsID >= 1 && wsID <= workspaceCount,
            var workspace = screenState.workspaces[wsID]
          else { continue }

          restoreColumns(
            from: persistedWS, into: &workspace, windowPool: windowPool, placed: &placed)
          screenState.workspaces[wsID] = workspace
        }

        state.screens[targetID] = screenState
      }
    }

    let unplaced = windowPool.values.filter { !placed.contains($0.id) }
    if !unplaced.isEmpty,
      let screenID = activeScreenID(),
      var screenState = state.screens[screenID],
      var ws1 = screenState.workspaces[1]
    {
      for window in unplaced {
        ws1.columns.append(
          Column(
            windows: [window],
            focusedWindowIndex: 0,
            widthFraction: layoutConfig.defaultColumnWidth
          ))
      }
      if ws1.focusedColumnIndex >= ws1.columns.count {
        ws1.focusedColumnIndex = max(0, ws1.columns.count - 1)
      }
      screenState.workspaces[1] = ws1
      state.screens[screenID] = screenState
    }

    setNeedsRetile()
    needsSave = true
    tiler_log(
      "Restored state: \(placed.count) windows placed, \(windowPool.count - placed.count) unplaced")
  }

  /// Restore columns into a workspace from a persisted workspace, tracking placed windows.
  private func restoreColumns(
    from persistedWS: PersistedWorkspace,
    into workspace: inout Workspace,
    windowPool: [CGWindowID: WindowNode],
    placed: inout Set<CGWindowID>
  ) {
    var restoredColumns: [Column] = []
    for persistedCol in persistedWS.columns {
      let liveWindows = persistedCol.windowIDs.compactMap { windowPool[$0] }
      guard !liveWindows.isEmpty else { continue }
      let mode: Column.ColumnMode = persistedCol.mode == "tab" ? .tab : .stack
      let clampedIdx = min(max(persistedCol.focusedWindowIndex, 0), liveWindows.count - 1)
      restoredColumns.append(
        Column(
          windows: liveWindows,
          focusedWindowIndex: clampedIdx,
          mode: mode,
          widthFraction: persistedCol.widthFraction
        ))
      placed.formUnion(liveWindows.map { $0.id })
    }
    workspace.columns = restoredColumns
    workspace.focusedColumnIndex =
      restoredColumns.isEmpty
      ? 0
      : min(max(persistedWS.focusedColumnIndex, 0), restoredColumns.count - 1)
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
    self.minWindowWidth = config.general.minWindowWidth
    self.minWindowHeight = config.general.minWindowHeight

    let oldCount = workspaceCount
    self.workspaceCount = max(1, config.workspaces.count)

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

    self.appRules = config.appRules
    setNeedsRetile()
    tiler_log("Applied new config (gaps=\(config.general), workspaces=\(workspaceCount))")
  }

  /// Returns all app rules whose `app` pattern matches the process's bundle identifier.
  private func matchingAppRules(pid: pid_t) -> [AppRuleConfig] {
    guard let app = NSRunningApplication(processIdentifier: pid),
      let bundleID = app.bundleIdentifier
    else { return [] }
    return appRules.filter { globMatch(pattern: $0.app, target: bundleID) }
  }

  /// Check whether the given window matches an app rule with action = "float".
  private func appRuleFloat(pid: pid_t) -> Bool {
    matchingAppRules(pid: pid).contains { $0.action == "float" }
  }

  // MARK: - Event handling

  private func handleEvent(_ event: TilerEvent) {
    switch event {
    case .appLaunched:
      setNeedsReconcile()
    case .appActivated(let pid):
      syncFocusFromActivatedApp(pid: pid)
    case .appTerminated(let pid):
      // Prune floating windows before windowStore forgets the pid
      floatingWindows = floatingWindows.filter { wid in
        guard let element = windowStore.element(for: wid) else { return false }
        var elementPid: pid_t = 0
        AXUIElementGetPid(element, &elementPid)
        return elementPid != pid
      }
      windowStore.forget(pid: pid)
      removeWindowsForPID(pid)
      setNeedsRetile()
    case .windowCreated:
      setNeedsReconcile()
    case .windowDestroyed(let element):
      let destroyedWID =
        windowStore.windowID(for: element) ?? windowStore.windowIDByIdentity(for: element)
      if let destroyedWID = destroyedWID {
        floatingWindows.remove(destroyedWID)
      }
      setNeedsReconcile()
    case .windowMinimized:
      setNeedsReconcile()
    case .windowDeminimized:
      setNeedsReconcile()
    case .focusChanged(let pid, let element):
      handleFocusChanged(pid: pid, element: element)
    case .geometryChanged(_, let element):
      guard let wid = windowStore.windowID(for: element) else { return }
      if floatingWindows.contains(wid) { return }

      let decision: EchoDecision
      if let observed = AXWindowBridge.currentFrame(for: element) {
        decision = classifyGeometryChange(
          observed: observed, applied: groupKey(forID: wid).flatMap { appliedWindows[$0]?.frame },
          tolerance: 2.0)
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
    // Build tileable set from CGWindowList + WindowStore
    guard
      let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else {
      tiler_log("reconcile: Could not get window list")
      return
    }

    windowStore.refresh(windowList: windowList, managedPIDs: managedPIDs)

    var tileableIDs: Set<CGWindowID> = []
    var notTileableCandidates: Set<CGWindowID> = []
    var noElementCandidates: Set<CGWindowID> = []
    var windowInfo: [CGWindowID: (pid: pid_t, title: String, bounds: NSRect)] = [:]
    var skippedNoElement = 0
    var skippedNotTileable = 0
    var totalCandidates = 0
    var allCGWindowIDs: Set<CGWindowID> = []

    for info in windowList {
      guard let wid = info[kCGWindowNumber as String] as? CGWindowID else { continue }
      allCGWindowIDs.insert(wid)
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
          notTileableCandidates.insert(wid)
          tiler_debug("reconcile: skip not-tileable wid=\(wid) title='\(title)' pid=\(pid)")
        }
      } else {
        skippedNoElement += 1
        noElementCandidates.insert(wid)
        tiler_debug("reconcile: skip no-element wid=\(wid) title='\(title)' pid=\(pid)")
      }
    }

    // AX-orphan pass: discover windows that are in the AX tree but hidden from
    // CGWindowListCopyWindowInfo (common in Chromium-based apps like Vivaldi).
    // These windows have a valid axGetWindowID and tileable AX element but never
    // appear in CGWindowList, so the main CG loop above misses them entirely.
    let cgPIDs = Set(windowInfo.values.map { $0.pid })
    for pid in managedPIDs.union(cgPIDs) {
      let storedWids = windowStore.wids(for: pid)
      let orphanWids = storedWids.subtracting(allCGWindowIDs)
      for wid in orphanWids {
        guard !tileableIDs.contains(wid), let element = windowStore.element(for: wid)
        else { continue }
        if WindowFilter.isTileable(element) {
          totalCandidates += 1
          // Populate windowInfo so the add loop can add this orphan window
          if windowInfo[wid] == nil {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            let axTitle = titleRef as? String ?? ""
            if let axBounds = AXWindowBridge.currentFrame(for: element) {
              // Convert from cocoa (bottom-left) to top-left for consistent windowInfo format
              let screenHeight = AXWindowBridge.primaryScreenHeight()
              let tlBounds = NSRect(
                x: axBounds.minX,
                y: screenHeight - axBounds.minY - axBounds.height,
                width: axBounds.width,
                height: axBounds.height)
              windowInfo[wid] = (pid, axTitle, tlBounds)
            }
          }
          tileableIDs.insert(wid)
          tiler_debug("reconcile: ax-orphan tileable wid=\(wid) pid=\(pid)")
        } else {
          skippedNotTileable += 1
          tiler_debug("reconcile: ax-orphan not-tileable wid=\(wid) pid=\(pid)")
        }
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
            else {
              // Window has no element mapping. Check if it's a transient SPI
              // failure (window still in AX tree but axGetWindowID failed) vs
              // actual destruction (window gone from AX entirely).
              if onScreenIDs.contains(window.id) {
                // Read AX window list for this PID to check if window still exists
                let appElement = AXUIElementCreateApplication(window.pid)
                var windowsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                  appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement]
                {
                  let isInAX = axWindows.contains { axGetWindowID($0) == window.id }
                  if isInAX {
                    stillAlive.insert(window.id)
                  }
                } else {
                  // Can't read AX tree — transient issue, keep alive
                  stillAlive.insert(window.id)
                }
              }
              continue
            }

            if onScreenIDs.contains(window.id) {
              stillAlive.insert(window.id)
              continue
            }
            // Absent from the on-screen list. Keep it if it has no applied frame yet (just
            // added, not laid out) or if that frame is essentially off-screen (we parked
            // it); otherwise it is expected-visible but unrendered — a background tab.
            guard let frame = appliedWindows[window.groupKey]?.frame else {
              stillAlive.insert(window.id)
              continue
            }
            let overlap =
              min(frame.maxX, visibleFrame.maxX) - max(frame.minX, visibleFrame.minX)
            if overlap <= 50 {
              stillAlive.insert(window.id)
            } else {
              tiler_debug(
                "reconcile: background-tab drop wid=\(window.id) pid=\(window.pid) overlap=\(Int(overlap)) (absent from on-screen list)"
              )
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

    // Targeted position-resolve for windows whose AX element wasn't mapped by
    // WindowStore (axGetWindowID SPI lag). Includes both new (unmanaged) windows whose
    // AX element hasn't appeared yet, and managed windows that lost their mapping due
    // to a transient axGetWindowID failure during refresh(). Position-matching is safe
    // here because we match against unmapped AX windows only, with ambiguity detection.
    for wid in noElementCandidates {
      guard let info = windowInfo[wid] else { continue }
      guard let element = windowStore.tryPositionResolve(pid: info.pid, cgBounds: info.bounds)
      else { continue }
      windowStore.register(wid: wid, element: element, pid: info.pid)
      noElementCandidates.remove(wid)
      if WindowFilter.isTileable(element) {
        tileableIDs.insert(wid)
        tiler_debug("reconcile: position-resolved tileable wid=\(wid) pid=\(info.pid)")
      } else {
        notTileableCandidates.insert(wid)
        tiler_debug("reconcile: position-resolved not-tileable wid=\(wid) pid=\(info.pid)")
      }
    }

    // CGWindowList can return empty/near-empty for hundreds of ms after display wake.
    // Only treat the pass as a mass disappearance when the scan itself returned no
    // on-screen windows. If other windows are visible, managed windows being absent is
    // genuine (closed/minimized) and should be reaped normally rather than suppressed.
    let massDisappearance = !managedIDs.isEmpty && stillAlive.isEmpty && onScreenIDs.isEmpty

    let reapingAllowed: Bool
    if let deadline = reapSuppressedUntil, Date() < deadline {
      reapingAllowed = false
    } else {
      reapingAllowed = !massDisappearance
    }

    if massDisappearance {
      tiler_log(
        "reconcile: mass disappearance (\(managedIDs.count) managed, 0 alive) — suppressing reap, scheduling retry"
      )
      missPendingToken &+= 1
      let token = missPendingToken
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        guard let self = self, self.missPendingToken == token else { return }
        self.setNeedsReconcile()
      }
    }

    let plan = reconcilePlan(
      managedIDs: managedIDs,
      stillAliveIDs: stillAlive,
      tileableIDs: tileableIDs,
      missingCounts: missingCounts,
      missThreshold: 2,
      unresolvedIDs: notTileableCandidates.subtracting(managedIDs),
      noElementIDs: noElementCandidates.subtracting(managedIDs),
      resolveCounts: resolveCounts,
      resolveThreshold: 8,
      reapingAllowed: reapingAllowed)
    missingCounts = plan.updatedMissingCounts
    resolveCounts = plan.updatedResolveCounts
    tiler_debug(
      "reconcile: tileable=\(tileableIDs.sorted()) managed=\(managedIDs.sorted()) stillAlive=\(stillAlive.sorted()) toAdd=\(plan.toAdd.sorted()) toReap=\(plan.toReap.sorted())"
    )

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
          guard let frame = appliedWindows[win.groupKey]?.frame else { return nil }
          return (win.id, win.pid, frame)
        }

      let vanished = Set(managedInActiveWS.map { $0.id }).subtracting(stillAlive)
      var consumed: Set<CGWindowID> = []

      // The new window's CGWindowList bounds are top-left origin; managed tiles' applied
      // frames are Cocoa bottom-left. Convert before matching so all four edges (including
      // Y) are comparable — Y is essential to tell vertically-stacked same-pid windows apart.
      let screenHeight = AXWindowBridge.primaryScreenHeight()

      for newID in adjustedToAdd.sorted() {
        guard let info = windowInfo[newID] else { continue }
        let cocoaBounds = NSRect(
          x: info.bounds.minX,
          y: screenHeight - info.bounds.minY - info.bounds.height,
          width: info.bounds.width,
          height: info.bounds.height)

        let matchedWIDs = windowIDsAtFrame(pid: info.pid, cocoaFrame: cocoaBounds, tolerance: 10)
        // Find managed windows at this frame: on-screen WIDs from the CG scan, or vanished
        // managed windows whose applied frame still matches.
        let candidates = managedInActiveWS.filter { v in
          v.pid == info.pid && !consumed.contains(v.id)
            && (matchedWIDs.contains(v.id)
              || (vanished.contains(v.id) && framesMatch(cocoaBounds, v.applied, tolerance: 10)))
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
            tiler_debug(
              "reconcile: reaping wid=\(w.id) pid=\(w.pid) title='\(w.title)' from ws=\(wsID)")
          }
          workspace.columns[colIdx].windows.removeAll { plan.toReap.contains($0.id) }
          if workspace.columns[colIdx].windows.count < before {
            changed = true
            membershipChanged = true
            workspace.columns[colIdx].measuredMinWidth = nil
            workspace.columns[colIdx].measuredMinHeight = nil
          }
          if workspace.columns[colIdx].windows.isEmpty {
            workspace.columns.remove(at: colIdx)
            changed = true
            membershipChanged = true
          } else if workspace.columns[colIdx].focusedWindowIndex
            >= workspace.columns[colIdx].windows.count
          {
            workspace.columns[colIdx].focusedWindowIndex =
              workspace.columns[colIdx].windows.count - 1
            changed = true
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

    // When no-element windows disappear (transient backing windows replaced),
    // schedule one final retry in case the real window appears with a different
    // CGWindowID shortly after.
    if hadNoElementLastPass && noElementCandidates.isEmpty {
      resolveRetryToken &+= 1
      let token = resolveRetryToken
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        guard let self = self, self.resolveRetryToken == token else { return }
        self.setNeedsReconcile()
      }
    }
    hadNoElementLastPass = !noElementCandidates.isEmpty

    // Detect windows that transitioned from not-tileable (fullscreen, minimized) back
    // to tileable. Reset stale measuredMinWidth/measuredMinHeight for their columns —
    // these may have been absorbed during the non-tileable phase (e.g. a fullscreen
    // window's width was absorbed as a min-width, locking the column at screen width).
    // The not-tileable set is kept sticky for managed windows: a fullscreen window may
    // vanish from CGWindowList for several reconcile passes during the Space transition,
    // and we need to remember it was not-tileable until it returns as tileable or is reaped.
    let becameTileable = tileableIDs.intersection(wasNotTileableLastPass)
    if !becameTileable.isEmpty {
      for (screenID, var screenState) in state.screens {
        for (wsID, var workspace) in screenState.workspaces {
          for colIdx in workspace.columns.indices {
            if workspace.columns[colIdx].windows.contains(where: { becameTileable.contains($0.id) })
            {
              workspace.columns[colIdx].measuredMinWidth = nil
              workspace.columns[colIdx].measuredMinHeight = nil
              tiler_debug(
                "reconcile: reset measuredMinWidth/Height for col \(colIdx) ws=\(wsID) (window exited fullscreen/minimized)"
              )
            }
          }
          screenState.workspaces[wsID] = workspace
        }
        state.screens[screenID] = screenState
      }
      setNeedsRetile()
    }
    // Sticky not-tileable tracking: keep managed IDs that are still not-tileable or
    // absent this pass (fullscreen Space transitions cause CGWindowList absence).
    // Drop IDs that became tileable or were reaped (no longer in state).
    let managedIDsAfterReap = Set(
      state.screens.values.flatMap { $0.workspaces.values }.flatMap { $0.columns }.flatMap {
        $0.windows
      }.map { $0.id })
    wasNotTileableLastPass = (wasNotTileableLastPass.union(notTileableCandidates))
      .intersection(managedIDsAfterReap)
      .subtracting(tileableIDs)

    if plan.hasPendingMiss {
      missPendingToken &+= 1
      let token = missPendingToken
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self = self, self.missPendingToken == token else { return }
        self.setNeedsReconcile()
      }
    }

    if plan.hasPendingResolve || plan.hasPendingNoElementResolve {
      resolveRetryToken &+= 1
      let token = resolveRetryToken
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        guard let self = self, self.resolveRetryToken == token else { return }
        self.setNeedsReconcile()
      }
    }

    // Add new windows
    for wid in adjustedToAdd {
      guard let (pid, title, bounds) = windowInfo[wid] else { continue }
      if floatingWindows.contains(wid) {
        continue  // manual toggle or app-rule float — persists
      }
      if appRuleFloat(pid: pid) {
        floatingWindows.insert(wid)  // first sight of an app-rule float
        tiler_debug("reconcile: float (app-rule) wid=\(wid) pid=\(pid) title='\(title)'")
        continue
      }
      if bounds.width < minWindowWidth || bounds.height < minWindowHeight {
        continue  // below-min: skip, re-evaluated next reconcile
      }
      // Require continuous bounds stability for settleDuration before tiling.
      // First reconcile skips settling so windows are available in windowPool for
      // restoreState immediately. Subsequent reconciles require bounds stability.
      if !isFirstReconcile {
        let now = Date()
        if let prev = settlingWindows[wid], framesMatch(prev.bounds, bounds, tolerance: 1) {
          if now.timeIntervalSince(prev.stableSince) >= settleDuration {
            settlingWindows.removeValue(forKey: wid)
            // stable long enough — fall through to addWindowToActiveWorkspace
          } else {
            continue  // stable but not long enough yet
          }
        } else {
          settlingWindows[wid] = (stableSince: now, bounds: bounds)
          tiler_debug("reconcile: settling wid=\(wid) pid=\(pid) bounds=\(bounds)")
          continue  // first sighting or bounds changed — not stable yet
        }
      }
      addWindowToActiveWorkspace(windowID: wid, pid: pid, title: title, bounds: bounds)
      membershipChanged = true
    }

    // Prune settle records for windows no longer in add candidates (closed during animation)
    settlingWindows = settlingWindows.filter { adjustedToAdd.contains($0.key) }
    if isFirstReconcile {
      isFirstReconcile = false
    }

    if !settlingWindows.isEmpty {
      settleRecheckToken &+= 1
      let token = settleRecheckToken
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        guard let self = self, self.settleRecheckToken == token else { return }
        self.setNeedsReconcile()
      }
    }

    if membershipChanged {
      setNeedsRetile()
    }
    if membershipChanged { needsSave = true }

    // Pending-focus replay: retry focus that arrived before its window was tiled.
    // Runs after tab swaps and additions so the tile already has the correct CGWindowID.
    // Retry until resolved (up to 8 attempts) — only clear on success. If the stored
    // element is stale (e.g. clobbered by a wid=0 Finder burst), fall back to reading
    // the current focused window from AX for the stored pid (read-only, no raise).
    if let pending = pendingFocus {
      var replayWid =
        pending.wid
        ?? windowStore.windowID(for: pending.element)
        ?? windowStore.windowIDByIdentity(for: pending.element)

      if replayWid == nil {
        let appElement = AXUIElementCreateApplication(pending.pid)
        var focusedWindowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
          appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef
        ) == .success, let ref = focusedWindowRef {
          let winElement = ref as! AXUIElement
          replayWid =
            windowStore.windowID(for: winElement)
            ?? windowStore.windowIDByIdentity(for: winElement)
          tiler_debug(
            "pendingFocus: stored element stale, AX fallback wid=\(replayWid.map { "\($0)" } ?? "nil") pid=\(pending.pid)"
          )
        }
      }

      if let wid = replayWid, updateFocus(windowID: wid) {
        tiler_debug("pendingFocus: replay succeeded wid=\(wid) attempts=\(pendingFocusAttempts)")
        pendingFocus = nil
        pendingFocusAttempts = 0
      } else {
        pendingFocusAttempts += 1
        if pendingFocusAttempts >= 8 {
          tiler_log(
            "pendingFocus: giving up after \(pendingFocusAttempts) attempts wid=\(replayWid.map { "\($0)" } ?? "nil")"
          )
          pendingFocus = nil
          pendingFocusAttempts = 0
        } else {
          tiler_debug(
            "pendingFocus: not yet tiled, attempt \(pendingFocusAttempts)/8 wid=\(replayWid.map { "\($0)" } ?? "nil")"
          )
          setNeedsReconcile()
        }
      }
    }

    // Prune appliedWindows for windows no longer in state
    let liveGroupKeys = Set(
      state.screens.values.flatMap { $0.workspaces.values }.flatMap { $0.columns }.flatMap {
        $0.windows
      }.map { $0.groupKey })
    appliedWindows = appliedWindows.filter { liveGroupKeys.contains($0.key) }
  }

  private func handleFocusChanged(pid: pid_t, element: AXUIElement) {
    var wid = windowStore.windowID(for: element) ?? windowStore.windowIDByIdentity(for: element)
    // Use the resolved element for downstream frame reads / pending storage. When the
    // notification element is stale we replace it with the live focused window below.
    var focusElement = element

    // The notification element can be stale or fail to resolve (transient _AXUIElementGetWindow
    // failure). Re-derive the focused window from kAXFocusedWindowAttribute before queuing a
    // replay — this is the same fallback used in the pendingFocus replay path below. Carry the
    // resolved element forward so the screen update and pending replay use the live focused
    // window, not the stale notification element.
    if wid == nil {
      let appElement = AXUIElementCreateApplication(pid)
      var focusedWindowRef: CFTypeRef?
      if AXUIElementCopyAttributeValue(
        appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef
      ) == .success, let ref = focusedWindowRef {
        let winElement = ref as! AXUIElement
        wid =
          windowStore.windowID(for: winElement)
          ?? windowStore.windowIDByIdentity(for: winElement)
        if wid != nil {
          focusElement = winElement
          tiler_debug(
            "handleFocusChanged: notification element stale, AX fallback wid=\(wid!) pid=\(pid)")
        }
      }
    }

    guard let wid = wid else {
      if let axFrame = AXWindowBridge.currentFrame(for: focusElement) {
        let midpoint = CGPoint(x: axFrame.midX, y: axFrame.midY)
        if let id = NSScreen.screens.first(where: { $0.visibleFrame.contains(midpoint) })?.displayID
        {
          focusedScreenID = id
        }
      }
      pendingFocus = (wid: nil, element: focusElement, pid: pid)
      pendingFocusAttempts = 0
      tiler_log("handleFocusChanged: axGetWindowID failed for pid \(pid), queuing focus replay")
      setNeedsReconcile()
      return
    }

    // Floating windows are not managed by the tiler
    if floatingWindows.contains(wid) {
      return
    }

    if updateFocus(windowID: wid) {
      pendingFocus = nil
      return
    }

    // wid resolved but not yet in any tiled column (e.g. fresh tab CGWindowID pre-reconcile)
    if let axFrame = AXWindowBridge.currentFrame(for: focusElement) {
      let midpoint = CGPoint(x: axFrame.midX, y: axFrame.midY)
      if let id = NSScreen.screens.first(where: { $0.visibleFrame.contains(midpoint) })?.displayID {
        focusedScreenID = id
      }
    }
    pendingFocus = (wid: wid, element: focusElement, pid: pid)
    pendingFocusAttempts = 0
    tiler_log("handleFocusChanged: wid \(wid) not yet tiled, queuing focus replay")
    setNeedsReconcile()
  }

  /// Handles the app-activation case `kAXFocusedWindowChangedNotification` misses:
  /// that notification only fires on intra-app focus changes, so a Cmd+Tab or
  /// cross-app click to an already-running app leaves the tiled focus indices stale.
  private func syncFocusFromActivatedApp(pid: pid_t) {
    // An activation is the latest focus truth, so it supersedes any prior
    // unresolved pending focus from kAXFocusedWindowChangedNotification —
    // otherwise the accompanying reconcile could replay that stale entry and
    // overwrite the focus we are about to set here.
    pendingFocus = nil
    pendingFocusAttempts = 0

    let appElement = AXUIElementCreateApplication(pid)
    var focusedWindowRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef) == .success,
      let ref = focusedWindowRef
    else {
      syncFocusedScreenFromAX()
      return
    }
    let winElement = ref as! AXUIElement
    let wid =
      windowStore.windowID(for: winElement) ?? windowStore.windowIDByIdentity(for: winElement)
    guard let wid = wid else {
      // Focused window exists but its CGWindowID can't be resolved. Keep the
      // screen in sync from its frame so navigation still targets the right screen.
      if let axFrame = AXWindowBridge.currentFrame(for: winElement) {
        let midpoint = CGPoint(x: axFrame.midX, y: axFrame.midY)
        if let id = NSScreen.screens.first(where: { $0.visibleFrame.contains(midpoint) })?.displayID
        {
          focusedScreenID = id
        }
      }
      return
    }
    if floatingWindows.contains(wid) {
      return
    }
    if updateFocus(windowID: wid) {
      return
    }
    // wid resolved but not yet in any tiled column (e.g. a fresh tab CGWindowID
    // pre-reconcile). Queue a replay so reconcile updates the focus indices once
    // the window is adopted, mirroring handleFocusChanged.
    pendingFocus = (wid: wid, element: winElement, pid: pid)
    pendingFocusAttempts = 0
    setNeedsReconcile()
  }

  /// At startup no `didActivateApplicationNotification` has fired yet, so the
  /// frontmost app's focus would otherwise be untracked.
  public func syncFocusFromFrontmostApp() {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
    syncFocusFromActivatedApp(pid: frontApp.processIdentifier)
  }

  // MARK: - State mutations

  private func activeScreenID() -> ScreenID? {
    if let id = focusedScreenID, state.screens[id] != nil {
      return id
    }
    if let keyWindowScreen = NSScreen.main ?? NSScreen.screens.first {
      let screenID = keyWindowScreen.displayID ?? CGMainDisplayID()
      if state.screens[screenID] != nil {
        return screenID
      }
    }
    return state.screens.keys.first ?? CGMainDisplayID()
  }

  private func orderedScreenIDs() -> [ScreenID] {
    state.screens.keys.sorted {
      let a = state.screens[$0]?.info.visibleFrame ?? .zero
      let b = state.screens[$1]?.info.visibleFrame ?? .zero
      return a.minX != b.minX ? a.minX < b.minX : a.minY < b.minY
    }
  }

  private func screenID(for bounds: NSRect) -> ScreenID? {
    // Prefer the focused screen so new windows appear on the screen
    // the user is currently working on, not where macOS placed them.
    if let focusedID = focusedScreenID, state.screens[focusedID] != nil {
      return focusedID
    }
    let mid = NSPoint(x: bounds.midX, y: bounds.midY)
    for (id, ss) in state.screens where ss.info.visibleFrame.contains(mid) {
      return id
    }
    return activeScreenID()
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

  private func addWindowToActiveWorkspace(
    windowID: CGWindowID, pid: pid_t, title: String, bounds: NSRect
  ) {
    guard let screenID = screenID(for: bounds),
      var screenState = state.screens[screenID],
      var workspace = screenState.workspaces[screenState.activeWorkspaceID]
    else { return }

    let wsID = screenState.activeWorkspaceID

    let node = WindowNode(id: windowID, groupKey: mintGroupKey(), pid: pid, title: title)

    // Native tab merge: windows of the same PID sharing the same frame
    // (background tabs stacked behind the active tab) belong in one tab column.
    let screenHeight = AXWindowBridge.primaryScreenHeight()
    let cocoaBounds = NSRect(
      x: bounds.minX,
      y: screenHeight - bounds.minY - bounds.height,
      width: bounds.width,
      height: bounds.height)
    // Check focused column first
    let focusedIdx = workspace.focusedColumnIndex
    if focusedIdx < workspace.columns.count {
      let col = workspace.columns[focusedIdx]
      if let firstWin = col.windows.first(where: { $0.pid == pid }) {
        let existingFrame: NSRect?
        if let element = windowStore.element(for: firstWin.id) {
          existingFrame = AXWindowBridge.currentFrame(for: element)
        } else if let gk = groupKey(forID: firstWin.id), let applied = appliedWindows[gk]?.frame {
          existingFrame = applied
        } else {
          existingFrame = nil
        }
        if let existingFrame = existingFrame,
          AXWindowBridge.framesMatch(cocoaBounds, existingFrame, tolerance: 10)
        {
          workspace.columns[focusedIdx].windows.append(node)
          if workspace.columns[focusedIdx].mode == .stack {
            workspace.columns[focusedIdx].mode = .tab
          }
          screenState.workspaces[wsID] = workspace
          state.screens[screenID] = screenState
          tiler_debug("Tab-merged window \(windowID) into focused column \(focusedIdx)")
          return
        }
      }
    }
    // Fall through to other columns (skip focusedIdx since already checked)
    for idx in workspace.columns.indices where idx != focusedIdx {
      let col = workspace.columns[idx]
      guard let firstWin = col.windows.first(where: { $0.pid == pid }) else { continue }
      let existingFrame: NSRect?
      if let element = windowStore.element(for: firstWin.id) {
        existingFrame = AXWindowBridge.currentFrame(for: element)
      } else if let gk = groupKey(forID: firstWin.id), let applied = appliedWindows[gk]?.frame {
        existingFrame = applied
      } else {
        existingFrame = nil
      }
      if let existingFrame = existingFrame,
        AXWindowBridge.framesMatch(cocoaBounds, existingFrame, tolerance: 10)
      {
        workspace.columns[idx].windows.append(node)
        if workspace.columns[idx].mode == .stack { workspace.columns[idx].mode = .tab }
        screenState.workspaces[wsID] = workspace
        state.screens[screenID] = screenState
        tiler_debug("Tab-merged window \(windowID) into column \(idx)")
        return
      }
    }

    // Preserve the window's current width as a fraction of usable viewport width.
    let usableWidth = LayoutGeometry.usableWidth(screenState.info, gaps)
    let widthFraction =
      usableWidth > 0
      ? min(max(bounds.width / usableWidth, 0.1), 1.0)
      : layoutConfig.defaultColumnWidth

    let column = Column(
      windows: [node], focusedWindowIndex: 0, widthFraction: widthFraction)

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
    tiler_debug(
      "Added window \(windowID) (\(title)) to workspace \(wsID) column \(workspace.focusedColumnIndex)"
    )
  }

  /// Replace a managed window's id in-place (for native-tab active-window changes).
  /// The new node keeps the old node's position within its column.
  private func swapWindowID(from oldID: CGWindowID, to newID: CGWindowID, title: String) {
    if state.swapWindowID(from: oldID, to: newID, title: title) {
      needsSave = true
    }
  }

  private func removeWindow(windowID: CGWindowID) {
    for (screenID, var screenState) in state.screens {
      for (wsID, var workspace) in screenState.workspaces {
        for (colIdx, var column) in workspace.columns.enumerated() {
          guard let removeIdx = column.windows.firstIndex(where: { $0.id == windowID })
          else { continue }
          let removedKey = column.windows[removeIdx].groupKey
          column.windows.remove(at: removeIdx)

          if column.windows.isEmpty {
            workspace.columns.remove(at: colIdx)
            if workspace.focusedColumnIndex >= workspace.columns.count && !workspace.columns.isEmpty
            {
              workspace.focusedColumnIndex = workspace.columns.count - 1
            }
          } else {
            if column.focusedWindowIndex >= column.windows.count {
              column.focusedWindowIndex = column.windows.count - 1
            }
            column.measuredMinWidth = nil
            column.measuredMinHeight = nil
            workspace.columns[colIdx] = column
          }

          screenState.workspaces[wsID] = workspace
          state.screens[screenID] = screenState
          appliedWindows.removeValue(forKey: removedKey)
          tiler_log("Removed window \(windowID) from workspace \(wsID)")
          return
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
          let removedKeys = workspace.columns[colIdx].windows.filter { $0.pid == pid }.map {
            $0.groupKey
          }
          workspace.columns[colIdx].windows.removeAll { $0.pid == pid }
          if workspace.columns[colIdx].windows.count < before {
            changed = true
            for gk in removedKeys { appliedWindows.removeValue(forKey: gk) }
            workspace.columns[colIdx].measuredMinWidth = nil
            workspace.columns[colIdx].measuredMinHeight = nil
          }
          if workspace.columns[colIdx].windows.isEmpty {
            workspace.columns.remove(at: colIdx)
            changed = true
          } else if workspace.columns[colIdx].focusedWindowIndex
            >= workspace.columns[colIdx].windows.count
          {
            workspace.columns[colIdx].focusedWindowIndex =
              workspace.columns[colIdx].windows.count - 1
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

  @discardableResult
  private func updateFocus(windowID: CGWindowID) -> Bool {
    for (screenID, var screenState) in state.screens {
      for (wsID, var workspace) in screenState.workspaces {
        for (colIdx, var column) in workspace.columns.enumerated() {
          if let winIdx = column.windows.firstIndex(where: { $0.id == windowID }) {
            column.focusedWindowIndex = winIdx
            workspace.columns[colIdx] = column
            workspace.focusedColumnIndex = colIdx
            screenState.workspaces[wsID] = workspace
            state.screens[screenID] = screenState
            focusedScreenID = screenID
            return true
          }
        }
      }
    }
    return false
  }

  /// The stable groupKey of the tile currently backed by `wid`, or nil if `wid` isn't a tile.
  private func groupKey(forID wid: CGWindowID) -> WindowNode.GroupKey? {
    for screenState in state.screens.values {
      for workspace in screenState.workspaces.values {
        for column in workspace.columns {
          if let node = column.windows.first(where: { $0.id == wid }) { return node.groupKey }
        }
      }
    }
    return nil
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
    if case .dumpFrameState = action {
      dumpFrameDiagnostics()
      return
    }
    if case .toggleFloat = action {
      toggleFloatActiveWindow()
      return
    }
    // Refresh focusedScreenID from the live AX focused window before computing the reducer
    // env. Without this, focusedScreenID can drift from actual OS focus when the user clicks
    // a window on another screen and no kAXFocusedWindowChangedNotification reaches us (or
    // the notification element failed to resolve), causing navigation to target the wrong
    // screen/workspace.
    syncFocusedScreenFromAX()
    let effects = Reducer.apply(action, to: &state, env: computeEnv())
    runEffects(effects)
    needsSave = true
  }

  /// Update `focusedScreenID` from the live AX focused window. Called before navigation
  /// actions so stale focus state doesn't route h/l/j/k to the wrong screen. Only ever
  /// sets `focusedScreenID` (never clears it) — consistent with `updateFocus` and the
  /// focus event handlers.
  private func syncFocusedScreenFromAX() {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
    var focusedWindowRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef
      ) == .success,
      let ref = focusedWindowRef
    else { return }
    let winElement = ref as! AXUIElement
    guard let axFrame = AXWindowBridge.currentFrame(for: winElement) else { return }
    let midpoint = CGPoint(x: axFrame.midX, y: axFrame.midY)
    if let id = NSScreen.screens.first(where: { $0.visibleFrame.contains(midpoint) })?.displayID {
      focusedScreenID = id
    }
  }

  // MARK: - Floating windows

  /// Toggle the floating state of the currently-focused window.
  /// First resolves the live AX-focused window (so un-float works even when
  /// the window is not in tiled state), then falls back to the tiled focus path.
  private func toggleFloatActiveWindow() {
    // Try to resolve the live AX-focused window
    var axWID: CGWindowID?
    if let frontApp = NSWorkspace.shared.frontmostApplication {
      let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
      var focusedWindowRef: CFTypeRef?
      if AXUIElementCopyAttributeValue(
        appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef
      ) == .success, let ref = focusedWindowRef {
        let winElement = ref as! AXUIElement
        axWID = windowStore.windowID(for: winElement) ?? axGetWindowID(winElement)
      }
    }

    if let wid = axWID, floatingWindows.contains(wid) {
      // Un-float: remove from floating set and let reconcile re-tile it
      floatingWindows.remove(wid)
      setNeedsReconcile()
      needsSave = true
      tiler_log("Un-floated window wid=\(wid)")
      return
    }

    // Fall back to the tiled focus path for floating a tiled window
    guard let window = currentlyFocusedWindow() else {
      tiler_log("toggleFloat: no focused window")
      return
    }

    if floatingWindows.contains(window.id) {
      floatingWindows.remove(window.id)
      setNeedsReconcile()
      needsSave = true
      tiler_log("Un-floated window wid=\(window.id)")
    } else {
      floatingWindows.insert(window.id)
      removeWindow(windowID: window.id)
      setNeedsRetile()
      needsSave = true
      tiler_log("Floated window wid=\(window.id)")
    }
  }

  private func computeEnv() -> ReducerEnv {
    ReducerEnv(
      workspaceCount: workspaceCount,
      activeScreenID: activeScreenID(),
      orderedScreenIDs: orderedScreenIDs()
    )
  }
  private func runEffects(_ effects: [Effect]) {
    for effect in effects {
      switch effect {
      case .retile:
        setNeedsRetile()
      case .focusFocusedWindow(let screenID, let wsID):
        guard let screenState = state.screens[screenID],
          let workspace = screenState.workspaces[wsID]
        else { break }
        focusedScreenID = screenID
        focusFocusedWindow(in: workspace)
      case .raiseTabbedWindows(let screenID, let wsID):
        raiseTabbedWindows(screenID: screenID, wsID: wsID)
      case .closeWindow(let windowID):
        guard let element = windowStore.element(for: windowID) else { break }
        var closeButton: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButton)
        if let btn = closeButton {
          AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
        }
      case .toggleFullscreen(let windowID):
        guard let element = windowStore.element(for: windowID) else { break }
        var fullscreen: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &fullscreen)
        if result == .success, let isFullscreen = fullscreen as? Bool {
          AXUIElementSetAttributeValue(
            element, "AXFullScreen" as CFString, !isFullscreen as CFTypeRef)
          tiler_log("Toggled fullscreen on window \(windowID)")
        }
      case .refreshTabs(let screenID, let wsID):
        refreshActiveTabs(screenID: screenID, wsID: wsID)
      case .scheduleDeferredTabRefresh(let screenID, let wsID):
        scheduleDeferredTabRefresh(screenID: screenID, wsID: wsID)

      case .log(let message):
        tiler_log(message)
      }
    }
  }

  /// Refresh every tile in the workspace to its native-tab group's live active tab.
  /// A no-op for healthy tiles; an in-place id swap (groupKey preserved) for stale
  /// background-tab tiles. Returns true if any tile was adopted.
  @discardableResult
  private func refreshActiveTabs(screenID: ScreenID, wsID: WorkspaceID) -> Bool {
    guard let workspace = state.screens[screenID]?.workspaces[wsID] else { return false }
    // Snapshot the tiles first; swapWindowID mutates state during the loop.
    let tiles = workspace.columns.flatMap { $0.windows }
    var changed = false
    for node in tiles {
      guard let frame = appliedWindows[node.groupKey]?.frame else { continue }
      if let resolved = resolveActiveTabSwap(pid: node.pid, tileFrame: frame, currentID: node.id) {
        swapWindowID(from: node.id, to: resolved.newWID, title: resolved.newTitle)
        changed = true
        tiler_debug("tab refresh: tile \(node.id) -> \(resolved.newWID) (live active tab)")
      }
    }
    return changed
  }

  /// Re-run the active-tab refresh a few times after a structural change or a focus that
  /// landed on a stale tile. Ghostty intermittently drops a tab from its AX window list, so
  /// an immediate refresh can miss the live tab; this settle-and-retry catches it once the
  /// flicker clears. Token-coalesced: a newer schedule supersedes the previous chain, and a
  /// step only retiles when it actually adopted a tile.
  private func scheduleDeferredTabRefresh(screenID: ScreenID, wsID: WorkspaceID) {
    consumeRefreshToken &+= 1
    let token = consumeRefreshToken
    for delay in [0.15, 0.35, 0.6] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self = self, self.consumeRefreshToken == token else { return }
        if self.refreshActiveTabs(screenID: screenID, wsID: wsID) {
          self.setNeedsRetile()
        }
      }
    }
  }

  // MARK: - Focus helpers

  /// The currently-focused window node in the active workspace, or nil if no workspace/column/window is focused.
  private func currentlyFocusedWindow() -> WindowNode? {
    guard let screenID = activeScreenID(),
      let screenState = state.screens[screenID],
      let workspace = screenState.workspaces[screenState.activeWorkspaceID],
      !workspace.columns.isEmpty,
      workspace.focusedColumnIndex < workspace.columns.count
    else { return nil }

    let col = workspace.columns[workspace.focusedColumnIndex]
    guard col.focusedWindowIndex < col.windows.count else { return nil }
    return col.windows[col.focusedWindowIndex]
  }

  private func focusFocusedWindow(in workspace: Workspace) {
    guard !workspace.columns.isEmpty,
      workspace.focusedColumnIndex < workspace.columns.count
    else { return }
    let col = workspace.columns[workspace.focusedColumnIndex]
    guard !col.windows.isEmpty else { return }
    let focusedIdx = min(col.focusedWindowIndex, col.windows.count - 1)
    let window = col.windows[focusedIdx]
    tiler_debug(
      "focus: col=\(workspace.focusedColumnIndex) winIdx=\(focusedIdx) tile=\(window.id) pid=\(window.pid) tileFrame=\(String(describing: appliedWindows[window.groupKey]?.frame)) storedElement=\(windowStore.element(for: window.id) != nil)"
    )

    var targetElement = windowStore.element(for: window.id)
    var raisedWid = window.id
    var adopted = false

    // A native tab group has exactly one window in the on-screen CGWindowList (background
    // tabs are absent), so the on-screen window matching this tile's frame is the group's
    // currently-active tab. Switching tabs emits no usable notification, so our stored id
    // can be a stale sibling; raising it would force the app back to that tab. Resolve the
    // active tab and adopt its id in place, then raise it (a no-op for tab selection).
    if let tileFrame = appliedWindows[window.groupKey]?.frame,
      let resolved = resolveActiveTabSwap(
        pid: window.pid, tileFrame: tileFrame, currentID: window.id)
    {
      swapWindowID(from: window.id, to: resolved.newWID, title: resolved.newTitle)
      missingCounts.removeValue(forKey: window.id)
      resolveCounts.removeValue(forKey: window.id)
      targetElement = resolved.newElement
      raisedWid = resolved.newWID
      adopted = true
      tiler_debug("focus: tab adopt \(window.id) -> \(resolved.newWID)")
    }

    guard let element = targetElement else {
      tiler_debug(
        "focus: no element for tile=\(window.id) pid=\(window.pid) — fallback raise + reconcile")
      // The stored id is a dead/invisible tab and the active tab couldn't be adopted cleanly
      // (transient mid tab-switch, or it's tracked elsewhere). Fall back to raising whatever
      // on-screen window sits at this tile's frame so focus still lands on the group, then
      // activate the app and reconcile to repair the tile id.
      if let app = NSRunningApplication(processIdentifier: window.pid) {
        app.activate(options: [.activateIgnoringOtherApps])
        app.activate(options: [.activateIgnoringOtherApps])
      }
      if let tileFrame = appliedWindows[window.groupKey]?.frame,
        let fallback = windowAtFrame(pid: window.pid, frame: tileFrame)
      {
        AXUIElementSetAttributeValue(fallback, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementPerformAction(fallback, kAXRaiseAction as CFString)
      }
      setNeedsReconcile()
      if let sid = activeScreenID(), let wid = activeWorkspaceID() {
        scheduleDeferredTabRefresh(screenID: sid, wsID: wid)
      }
      return
    }

    // Move keyboard focus to the tile: mark it main, raise it, and activate the app.
    // First set kAXMainAttribute so the window becomes key, then raise it to bring it
    // to front. Some apps (Ghostty) need app.activate() called twice synchronously
    // to yield keyboard focus — the first call syncs internal state, the second
    // completes the transfer (AeroSpace pattern).
    AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, true as CFTypeRef)
    if let app = NSRunningApplication(processIdentifier: window.pid) {
      app.activate(options: [.activateIgnoringOtherApps])
      app.activate(options: [.activateIgnoringOtherApps])
    }
    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    tiler_debug("focus: ax raise wid=\(raisedWid) pid=\(window.pid)")

    // If we raised the stored tile without adopting an active tab, and that tile is absent
    // from the on-screen CGWindowList while we expect it visible (its applied frame
    // substantially overlaps the visible area), it is a native background tab rendering as
    // an invisible, unfocusable column. Kick a reconcile so the reaper collapses it now
    // rather than on the next window open/close.
    if !adopted,
      let frame = appliedWindows[window.groupKey]?.frame,
      let screenID = activeScreenID(),
      let visibleFrame = state.screens[screenID]?.info.visibleFrame
    {
      let overlap = min(frame.maxX, visibleFrame.maxX) - max(frame.minX, visibleFrame.minX)
      if overlap > 50, !isOnScreen(window.id) {
        tiler_debug("focus: tile=\(window.id) is a visible background tab — kicking reconcile")
        setNeedsReconcile()
        if let sid = activeScreenID(), let wid = activeWorkspaceID() {
          scheduleDeferredTabRefresh(screenID: sid, wsID: wid)
        }
      }
    }
  }

  private func raiseTabbedWindows(screenID: ScreenID, wsID: WorkspaceID) {
    guard let workspace = state.screens[screenID]?.workspaces[wsID],
      !workspace.columns.isEmpty,
      workspace.focusedColumnIndex < workspace.columns.count
    else { return }
    let col = workspace.columns[workspace.focusedColumnIndex]
    guard col.mode == .tab, col.windows.count > 1 else { return }

    var displayOrder = col.windows
    let _ = displayOrder.remove(at: col.focusedWindowIndex)
    displayOrder.append(col.windows[col.focusedWindowIndex])
    for i in 0..<(displayOrder.count - 1) {
      if let el = windowStore.element(for: displayOrder[i].id) {
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
      }
    }
  }

  /// Scan the on-screen CGWindowList for windows matching `pid` whose frame
  /// (converted from CG top-left → Cocoa bottom-left) matches `cocoaFrame`
  /// within tolerance. Returns the list of matching CGWindowIDs in CGWindowList
  /// order (typically front-to-back, best-effort).
  private func windowIDsAtFrame(pid: pid_t, cocoaFrame: NSRect, tolerance: CGFloat) -> [CGWindowID]
  {
    guard
      let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    let screenHeight = AXWindowBridge.primaryScreenHeight()
    var matches: [CGWindowID] = []
    for info in list {
      guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
        let wid = info[kCGWindowNumber as String] as? CGWindowID,
        let layer = info[kCGWindowLayer as String] as? Int, layer <= 0,
        let b = info[kCGWindowBounds as String] as? [String: CGFloat]
      else { continue }
      let cocoaY = screenHeight - (b["Y"] ?? 0) - (b["Height"] ?? 0)
      let converted = NSRect(
        x: b["X"] ?? 0, y: cocoaY, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
      if framesMatch(converted, cocoaFrame, tolerance: tolerance) {
        matches.append(wid)
      }
    }
    return matches
  }

  /// Resolve the active tab for a native tab group at `tileFrame`, returning the
  /// new window ID, title, and AX element when the active tab differs from `currentID`.
  /// Uses `windowIDsAtFrame` for initial matching, then an AX `kAXMainAttribute`
  /// tiebreaker when multiple on-screen windows match. Returns nil on ambiguity or
  /// when the active tab is already `currentID` or managed by another tile.
  private func resolveActiveTabSwap(
    pid: pid_t, tileFrame: NSRect, currentID: CGWindowID
  ) -> (newWID: CGWindowID, newTitle: String, newElement: AXUIElement)? {
    let matches = windowIDsAtFrame(pid: pid, cocoaFrame: tileFrame, tolerance: 10)
    if matches.isEmpty { return nil }

    var activeWid: CGWindowID?
    if matches.count == 1 {
      activeWid = matches[0]
    } else {
      // AX tiebreaker: among multiple frame-matched windows, prefer the one with main == true
      var mainCandidates: [CGWindowID] = []
      for match in matches {
        let element =
          windowStore.element(for: match) ?? windowStore.liveElement(forPID: pid, wid: match)
        guard let element = element else { continue }
        var val: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXMainAttribute as CFString, &val) == .success,
          let isMain = val as? Bool, isMain
        {
          mainCandidates.append(match)
        }
      }
      if mainCandidates.count == 1 {
        activeWid = mainCandidates[0]
      } else {
        // 0 or >1 with main == true — ambiguous, refuse to swap
        return nil
      }
    }

    guard let activeWid = activeWid,
      activeWid != currentID, !isManaged(activeWid)
    else { return nil }

    // Get title: re-scan CGWindowList for kCGWindowName, fallback to AX kAXTitleAttribute
    var title = ""
    if let list = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    {
      for info in list {
        if let wid = info[kCGWindowNumber as String] as? CGWindowID, wid == activeWid,
          let name = info[kCGWindowName as String] as? String, !name.isEmpty
        {
          title = name
          break
        }
      }
    }
    if title.isEmpty {
      let element =
        windowStore.element(for: activeWid) ?? windowStore.liveElement(forPID: pid, wid: activeWid)
      var val: AnyObject?
      if let element = element,
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &val) == .success,
        let t = val as? String
      {
        title = t
      }
    }

    guard
      let element = windowStore.element(for: activeWid)
        ?? windowStore.liveElement(forPID: pid, wid: activeWid)
    else { return nil }

    return (activeWid, title, element)
  }

  /// Best-effort: any on-screen window of `pid` physically located at `frame` (Cocoa
  /// coords), resolved to an AX element. Unlike `resolveActiveTabSwap` this applies no
  /// unique/unmanaged guard — it is only used to put focus on a group whose tile id has
  /// gone stale and whose active tab couldn't be adopted cleanly, so raising the wrong
  /// sibling is harmless (it's focus, not an id swap).
  private func windowAtFrame(pid: pid_t, frame: NSRect) -> AXUIElement? {
    let wids = windowIDsAtFrame(pid: pid, cocoaFrame: frame, tolerance: 10)
    for wid in wids {
      if let element = windowStore.element(for: wid)
        ?? windowStore.liveElement(forPID: pid, wid: wid)
      {
        return element
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

  private func hideInactiveWorkspaces() {
    guard activeScreenID() != nil, activeWorkspaceID() != nil
    else { return }

    var frames: [CGWindowID: NSRect] = [:]

    for (_, screenState) in state.screens {
      let visibleFrame = screenState.info.visibleFrame
      for (wsID, workspace) in screenState.workspaces {
        // Only park windows that are NOT on the active workspace of each screen
        guard wsID != screenState.activeWorkspaceID else { continue }
        for column in workspace.columns {
          for window in column.windows {
            let wid = window.id
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
      if let gk = groupKey(forID: wid) {
        appliedWindows[gk] = AppliedWindow(epoch: applyEpoch, frame: parked)
      }
    }
    AXWindowBridge.applyFrames(frames, store: windowStore)
    tiler_debug("Parked \(frames.count) windows from inactive workspaces")
  }

  // MARK: - Layout

  private func retileAllScreens() {
    applyEpoch &+= 1
    var allFrames: [CGWindowID: NSRect] = [:]
    for (screenID, var screenState) in state.screens {
      let wsID = screenState.activeWorkspaceID
      guard var workspace = screenState.workspaces[wsID] else { continue }
      let context = LayoutContext(screen: screenState.info, gaps: gaps)
      let output = LayoutResolver.resolve(workspace, context)
      workspace.scrollOffset = output.offset
      screenState.workspaces[wsID] = workspace
      state.screens[screenID] = screenState
      for column in workspace.columns {
        for node in column.windows {
          if let frame = output.frames[node.id] {
            appliedWindows[node.groupKey] = AppliedWindow(epoch: applyEpoch, frame: frame)
          }
        }
      }
      allFrames.merge(output.frames) { _, new in new }
    }
    AXWindowBridge.applyFrames(allFrames, store: windowStore)
    if !allFrames.isEmpty {
      tiler_debug("Laid out \(allFrames.count) windows across \(state.screens.count) screens")
    }
  }

  // MARK: - Corrector

  /// Re-issue frames for windows that haven't reached their desired geometry yet.
  /// Runs once per drain cycle; convergence is driven by incoming AX resize notifications.
  private func reconcilePendingFrames() {
    var idForGroup: [WindowNode.GroupKey: CGWindowID] = [:]
    for (_, screenState) in state.screens {
      guard let workspace = screenState.workspaces[screenState.activeWorkspaceID] else { continue }
      for column in workspace.columns {
        for node in column.windows { idForGroup[node.groupKey] = node.id }
      }
    }

    var reissues: [CGWindowID: NSRect] = [:]
    for (gk, record) in appliedWindows where record.epoch == applyEpoch && idForGroup[gk] != nil {
      let wid = idForGroup[gk]!
      guard let element = windowStore.element(for: wid) else { continue }
      guard let observed = AXWindowBridge.currentFrame(for: element) else { continue }

      if AXWindowBridge.framesMatch(observed, record.frame, tolerance: 2.0) {
        appliedWindows[gk]?.corrections = 0
      } else if (appliedWindows[gk]?.corrections ?? 0) < 3 {
        tiler_debug(
          "correct: wid=\(wid) re-issue attempt=\((appliedWindows[gk]?.corrections ?? 0) + 1) observed=\(observed) intended=\(record.frame)"
        )
        appliedWindows[gk]?.corrections += 1
        reissues[wid] = record.frame
      } else {
        // Budget exhausted: the window won't reach the exact frame (min-size or
        // character-cell quantization). If it's wider than desired, absorb that into
        // the column width; otherwise accept its actual settled frame as the echo
        // reference so future geometry events at this position are treated as echoes
        // (prevents the snap-back path from looping on quantized windows).
        tiler_debug(
          "correct: wid=\(wid) gave up after 3 tries — observed=\(observed) intended=\(record.frame)"
        )
        if observed.width > record.frame.width + 2.0 {
          absorbMinWidth(wid: wid, observedWidth: observed.width)
        } else if observed.height > record.frame.height + 2.0 {
          absorbMinHeight(wid: wid, observedHeight: observed.height)
        } else {
          appliedWindows[gk]?.frame = observed
        }
      }
    }

    // Re-issue all pending frames in a single batched write so EUI toggling and
    // per-process AX round-trips happen once per drain cycle instead of per window.
    if !reissues.isEmpty {
      AXWindowBridge.applyFrames(reissues, store: windowStore)
    }
  }

  // MARK: - Min-width absorption

  /// Record that a window resisted being narrower than observedWidth, and retile to accommodate.
  private func absorbMinWidth(wid: CGWindowID, observedWidth: CGFloat) {
    for (screenID, var screenState) in state.screens {
      let wsID = screenState.activeWorkspaceID
      guard var workspace = screenState.workspaces[wsID] else { continue }
      for colIdx in workspace.columns.indices {
        if workspace.columns[colIdx].windows.contains(where: { $0.id == wid }) {
          // Skip absorption when the observed width is at or beyond the usable screen
          // width. A genuine minimum width can never reach the usable width — that
          // would mean the window fills the entire tiling area, which only happens
          // during a fullscreen transition. Without this guard, a fullscreen window's
          // width gets absorbed as measuredMinWidth, permanently locking the column.
          let usableWidth = LayoutGeometry.usableWidth(screenState.info, gaps)
          guard observedWidth < usableWidth else {
            tiler_debug(
              "absorbMinWidth: skipping \(observedWidth) >= usable \(usableWidth) for wid=\(wid) (likely fullscreen transition)"
            )
            return
          }
          workspace.columns[colIdx].measuredMinWidth = max(
            workspace.columns[colIdx].measuredMinWidth ?? 0, observedWidth)
          screenState.workspaces[wsID] = workspace
          state.screens[screenID] = screenState
          setNeedsRetile()
          tiler_debug(
            "Absorbed min-width \(observedWidth) for wid=\(wid) in col \(colIdx) on screen \(screenID)"
          )
          return
        }
      }
    }
  }

  private func absorbMinHeight(wid: CGWindowID, observedHeight: CGFloat) {
    for (screenID, var screenState) in state.screens {
      let wsID = screenState.activeWorkspaceID
      guard var workspace = screenState.workspaces[wsID] else { continue }
      for colIdx in workspace.columns.indices {
        if workspace.columns[colIdx].windows.contains(where: { $0.id == wid }) {
          // Skip absorption when the observed height is at or beyond the usable
          // screen height — same rationale as absorbMinWidth above.
          let usableHeight = screenState.info.visibleFrame.height - 2 * gaps.outerGaps
          guard observedHeight < usableHeight else {
            tiler_debug(
              "absorbMinHeight: skipping \(observedHeight) >= usable \(usableHeight) for wid=\(wid) (likely fullscreen transition)"
            )
            return
          }
          workspace.columns[colIdx].measuredMinHeight = max(
            workspace.columns[colIdx].measuredMinHeight ?? 0, observedHeight)
          screenState.workspaces[wsID] = workspace
          state.screens[screenID] = screenState
          setNeedsRetile()
          tiler_debug(
            "Absorbed min-height \(observedHeight) for wid=\(wid) in col \(colIdx) on screen \(screenID)"
          )
          return
        }
      }
    }
  }

  // MARK: - Screen reconfiguration

  private func reconfigureScreens() {
    let current = NSScreen.screens

    var newInfos: [ScreenID: ScreenInfo] = [:]
    for screen in current {
      guard let id = screen.displayID else { continue }
      newInfos[id] = ScreenInfo(id: id, frame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    guard !newInfos.isEmpty else {
      tiler_log("reconfigureScreens: no screens have a display ID, preserving state")
      return
    }

    var newMap: [ScreenID: ScreenState] = [:]
    var usedOldIDs: Set<ScreenID> = []

    // Pass 1: Exact ID match — preserve existing workspaces
    for (newID, info) in newInfos {
      if let existing = state.screens[newID] {
        var transferred = existing
        transferred.info = info
        newMap[newID] = transferred
        usedOldIDs.insert(newID)
      }
    }

    // Pass 2: Position fallback for unmatched new screens
    let unmatchedNew = newInfos.filter { newMap[$0.key] == nil }
      .sorted {
        $0.value.visibleFrame.minX != $1.value.visibleFrame.minX
          ? $0.value.visibleFrame.minX < $1.value.visibleFrame.minX
          : $0.value.visibleFrame.minY < $1.value.visibleFrame.minY
      }
    let unmatchedOld = state.screens.keys
      .filter { !usedOldIDs.contains($0) }
      .sorted {
        let a = state.screens[$0]?.info.visibleFrame ?? .zero
        let b = state.screens[$1]?.info.visibleFrame ?? .zero
        return a.minX != b.minX ? a.minX < b.minX : a.minY < b.minY
      }

    for (i, (newID, info)) in unmatchedNew.enumerated() {
      if i < unmatchedOld.count, let oldState = state.screens[unmatchedOld[i]] {
        var transferred = oldState
        transferred.info = info
        newMap[newID] = transferred
        usedOldIDs.insert(unmatchedOld[i])
        tiler_log("Screen ID changed: \(unmatchedOld[i]) -> \(newID)")
      } else {
        // Extra new screen — create empty workspaces
        var workspaces: [WorkspaceID: Workspace] = [:]
        for j in 1...workspaceCount { workspaces[j] = Workspace(id: j) }
        newMap[newID] = ScreenState(info: info, workspaces: workspaces, activeWorkspaceID: 1)
        tiler_log("New display: \(newID)")
      }
    }

    // Log removed screens
    for oldID in state.screens.keys where !usedOldIDs.contains(oldID) {
      tiler_log("Display removed: \(oldID)")
    }

    state.screens = newMap
    setNeedsReconcile()
    setNeedsRetile()
  }

  /// Move all managed windows to visible positions on the main screen so the
  /// user isn't left with windows stranded off-screen after Tiler quits.
  /// Partially visible windows are snapped to the nearest edge; non-visible
  /// windows are centered on the main screen.
  public func gatherWindowsToMainScreen() {
    guard let mainScreen = NSScreen.screens.first else { return }
    let visibleFrame = mainScreen.visibleFrame

    // Collect all managed windows (preserving order: screen, workspace, column).
    var windows: [(wid: CGWindowID, element: AXUIElement)] = []
    for screenState in state.screens.values {
      for workspace in screenState.workspaces.values {
        for column in workspace.columns {
          for node in column.windows {
            if let element = windowStore.element(for: node.id) {
              windows.append((node.id, element))
            }
          }
        }
      }
    }

    guard !windows.isEmpty else { return }

    var frames: [CGWindowID: NSRect] = [:]

    for (wid, element) in windows {
      // Read the window's current size; only reposition, don't resize.
      guard let current = AXWindowBridge.currentFrame(for: element) else { continue }

      // If already fully visible on the main screen, leave it alone.
      if visibleFrame.contains(current) { continue }

      var target = current

      // Check if the window intersects the visible frame at all.
      let intersects = current.intersects(visibleFrame)

      if intersects {
        // Partially visible: snap to the nearest edge.
        if target.minX < visibleFrame.minX {
          target.origin.x = visibleFrame.minX
        } else if target.maxX > visibleFrame.maxX {
          target.origin.x = visibleFrame.maxX - target.width
        }
        if target.minY < visibleFrame.minY {
          target.origin.y = visibleFrame.minY
        } else if target.maxY > visibleFrame.maxY {
          target.origin.y = visibleFrame.maxY - target.height
        }
      } else {
        // Not visible at all: center on the main screen.
        target.origin.x = visibleFrame.midX - target.width / 2.0
        target.origin.y = visibleFrame.midY - target.height / 2.0
      }

      if target != current {
        frames[wid] = target
      }
    }

    guard !frames.isEmpty else { return }
    AXWindowBridge.applyFrames(frames, store: windowStore)
    tiler_log("Gathered \(frames.count) windows to the main screen on quit")
  }

  /// Write the PID list of all managed windows to the crash recovery file.
  /// Called periodically so the file is always current; the crash handler
  /// child process reads this file to know which windows to gather.
  public func writeCrashRecoveryFile() {
    let path = TilerCrashRecoveryFilePath() as String
    guard !path.isEmpty else { return }

    var pids = Set<pid_t>()
    for screenState in state.screens.values {
      for workspace in screenState.workspaces.values {
        for column in workspace.columns {
          for node in column.windows {
            pids.insert(node.pid)
          }
        }
      }
    }

    let pidArray = pids.sorted().map { NSNumber(value: $0) }
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: pidArray, options: [])
    else { return }
    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }

  /// Delete the crash recovery file. Called on clean shutdown so the next
  /// launch doesn't mistake a clean quit for a crash.
  public func deleteCrashRecoveryFile() {
    let path = TilerCrashRecoveryFilePath() as String
    guard !path.isEmpty else { return }
    try? FileManager.default.removeItem(atPath: path)
  }

  /// On launch, check if the crash recovery file exists (indicating the
  /// previous instance crashed). If so, gather stranded windows before
  /// starting normal operation, then remove the file.
  public func performCrashRecoveryIfNeeded() {
    let path = TilerCrashRecoveryFilePath() as String
    guard !path.isEmpty else { return }
    guard FileManager.default.fileExists(atPath: path) else { return }

    tiler_log("Crash recovery file found — gathering windows from previous crash")
    TilerCrashRecoveryGather()
    try? FileManager.default.removeItem(atPath: path)
  }

  public func saveState() {
    statePersistence.save(state)
  }

  // MARK: - Screen lock handling

  private func screenDidLock() {
    tiler_log("Screen locked: pausing periodic reconcile")
    reapSuppressedUntil = .distantFuture
    reconcileTimer?.invalidate()
    reconcileTimer = nil
  }

  private func screenDidUnlock() {
    tiler_log("Screen unlocked")
    missingCounts.removeAll()
    reapSuppressedUntil = Date(timeIntervalSinceNow: 3.0)
    if reconcileTimer == nil {
      reconcileTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
        self?.setNeedsReconcile()
      }
    }
    setNeedsReconcile()
    // Schedule a deferred reconcile at T+3.0s so reaping resumes promptly after suppression
    missPendingToken &+= 1
    let token = missPendingToken
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
      guard let self = self, self.missPendingToken == token else { return }
      self.setNeedsReconcile()
    }
    // Defer retile to let display geometry and AX elements settle after unlock
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.setNeedsRetile()
    }
  }

  private func dumpFrameDiagnostics() {
    let screenH = AXWindowBridge.primaryScreenHeight()
    tiler_log("[diagnostics] primaryScreenHeight=\(screenH) screens=\(state.screens.count)")
    for (sid, sst) in state.screens {
      let info = sst.info
      let og = gaps.outerGaps
      let usableRect = NSRect(
        x: info.visibleFrame.minX + og,
        y: info.visibleFrame.minY + og,
        width: max(0, info.visibleFrame.width - 2 * og),
        height: max(0, info.visibleFrame.height - 2 * og))
      tiler_log(
        "[diagnostics] screen=\(sid) frame=\(info.frame) visible=\(info.visibleFrame) usable=\(usableRect)"
      )
      let ws = sst.workspaces[sst.activeWorkspaceID]
      guard let ws else { continue }
      for (ci, col) in ws.columns.enumerated() {
        tiler_log(
          "[diagnostics]   col[\(ci)] mode=\(col.mode) wf=\(col.widthFraction) count=\(col.windows.count)"
        )
        for node in col.windows {
          let target = appliedWindows[node.groupKey]?.frame
          let actual = windowStore.element(for: node.id).flatMap {
            AXWindowBridge.currentFrame(for: $0)
          }
          var flags = [String]()
          if let t = target, t.minY < info.visibleFrame.minY {
            flags.append("BELOW visibleFrame.minY")
          }
          if let t = target, t.minY + t.height > info.visibleFrame.maxY {
            flags.append("ABOVE visibleFrame.maxY")
          }
          let flagStr = flags.isEmpty ? "" : " *** \(flags.joined(separator: ", ")) ***"
          tiler_log(
            "[diagnostics]     wid=\(node.id) pid=\(node.pid) target=\(String(describing: target)) actual=\(String(describing: actual))\(flagStr)"
          )
        }
      }
    }
  }
}
