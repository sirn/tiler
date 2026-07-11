import AppKit
import ApplicationServices
import TilerCore

class AppDelegate: NSObject, NSApplicationDelegate {
  private var eventBroker: EventBroker?
  private var windowManager: WindowManager?
  private var hotkeyDispatcher: HotkeyDispatcher?
  private var configLoader: ConfigLoader?
  private var statusBar: StatusBarController?
  private var permissionPollTimer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Install crash handlers early so we can recover even during startup.
    TilerInstallCrashHandlers()

    // Ensure accessibility permissions are granted
    if AXIsProcessTrusted() {
      startCore()
    } else {
      // Show the system "grant accessibility" dialog. macOS presents this at most
      // once per process launch on the first call; later calls are silent reads.
      let options: NSDictionary = [
        kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true
      ]
      _ = AXIsProcessTrustedWithOptions(options)
      tiler_log(
        "Accessibility permission required. Grant it in System Settings > "
        + "Privacy & Security > Accessibility; Tiler will start automatically once granted."
      )
      startPermissionPoll()
      // Show a degraded-mode menu bar item ("⚠ Grant Accessibility" + Exit Tiler
      // menu) so the user can quit without a terminal while waiting for permission.
      let statusBar = StatusBarController()
      self.statusBar = statusBar
      statusBar.setDegradedMode(true)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    windowManager?.gatherWindowsToMainScreen()
    windowManager?.deleteCrashRecoveryFile()
    windowManager?.saveState()
  }

  private func startCore() {
    guard windowManager == nil else { return }
    tiler_log("Accessibility permissions granted. Starting...")

    // Load config
    let loader = ConfigLoader()
    self.configLoader = loader
    let config = loader.load()

    // Set up event broker
    let broker = EventBroker()
    self.eventBroker = broker

    // Set up window manager with config
    let wm = WindowManager(eventBroker: broker, config: config)
    self.windowManager = wm

    // If the previous instance crashed, gather stranded windows before starting.
    wm.performCrashRecoveryIfNeeded()

    // Initialize screens and workspaces
    wm.initializeScreens()

    // Menu bar workspace indicator: transition the degraded-mode item if it
    // exists (set during the accessibility-poll phase), else create a new one.
    let statusBar: StatusBarController
    if let existing = self.statusBar {
      existing.setDegradedMode(false)
      statusBar = existing
    } else {
      statusBar = StatusBarController()
      self.statusBar = statusBar
    }
    if let indicator = wm.workspaceIndicator() {
      statusBar.update(occupied: indicator.occupied, current: indicator.current)
    }
    statusBar.setWorkspaceCount(wm.workspaceCount)
    statusBar.onSwitchWorkspace = { [weak wm] n in
      wm?.handleAction(.focusWorkspace(n))
    }
    statusBar.onToggleDebugLogging = {
      tilerDebugEnabled.toggle()
      tiler_log("Debug logging \(tilerDebugEnabled ? "enabled" : "disabled") via menu")
    }
    wm.onWorkspaceIndicatorChanged = { [weak statusBar] indicator in
      statusBar?.update(occupied: indicator.occupied, current: indicator.current)
    }

    // Start event listening (before reconcile so AX observers are registered)
    broker.start()

    // Reconcile existing windows (enumerate + diff against empty state)
    wm.reconcile()

    // Restore persisted workspace state
    wm.restoreState()

    // Sync tiled focus to the OS focus we launched into, since no
    // didActivateApplicationNotification fires for the already-frontmost app.
    wm.syncFocusFromFrontmostApp()

    // Start the coalescing drain loop
    wm.start()

    // Set up hotkey dispatcher
    let dispatcher = HotkeyDispatcher()
    let bindings = defaultKeybindings.merging(keybindingsFromConfig(config.keybinds)) { _, config in config }
    dispatcher.setBindings(bindings)
    dispatcher.setActionHandler { [weak self] action in
      self?.windowManager?.handleAction(action)
    }
    dispatcher.start()
    self.hotkeyDispatcher = dispatcher
  }

  /// Polls Accessibility trust state and runs `startCore()` on the first grant.
  /// Uses plain `AXIsProcessTrusted()` (no prompt) — the prompt was already shown
  /// at launch, mirroring coord's split between `check_and_prompt` (once) and
  /// `is_trusted` (polled). 2 s cadence matches the existing reconcile timer.
  private func startPermissionPoll() {
    permissionPollTimer = Timer.scheduledTimer(
      withTimeInterval: 2.0, repeats: true
    ) { [weak self] timer in
      guard let self = self else { timer.invalidate(); return }
      guard AXIsProcessTrusted() else { return }
      timer.invalidate()
      self.permissionPollTimer = nil
      tiler_log("Accessibility permission granted; launching core.")
      self.startCore()
    }
  }

  // MARK: - Keybind helpers

  /// Convert config keybinds into HotkeyDispatcher bindings.
  private func keybindingsFromConfig(_ keybinds: [KeybindConfig]) -> [KeyCombo: Action] {
    var bindings: [KeyCombo: Action] = [:]
    for kb in keybinds {
      guard let combo = KeyCombo.parse(kb.keys),
        let action = Action.parse(kb.action, args: kb.args)
      else {
        tiler_log("Skipping invalid keybind: keys=\(kb.keys) action=\(kb.action)")
        continue
      }
      bindings[combo] = action
    }
    return bindings
  }

  /// Hardcoded default keybindings (used when no config keybinds are provided).
  private var defaultKeybindings: [KeyCombo: Action] {
    var bindings: [KeyCombo: Action] = [:]

    // Navigation
    bindings[.parse("ctrl+alt+h")!] = .focusColumnLeft
    bindings[.parse("ctrl+alt+l")!] = .focusColumnRight
    bindings[.parse("ctrl+alt+j")!] = .focusWindowDown
    bindings[.parse("ctrl+alt+k")!] = .focusWindowUp

    // Move
    bindings[.parse("ctrl+alt+shift+h")!] = .moveColumnLeft
    bindings[.parse("ctrl+alt+shift+l")!] = .moveColumnRight
    bindings[.parse("ctrl+alt+shift+j")!] = .moveWindowDown
    bindings[.parse("ctrl+alt+shift+k")!] = .moveWindowUp

    // Workspace focus (1..9)
    for i in 1...9 {
      if let combo = KeyCombo.parse("ctrl+alt+\(i)") {
        bindings[combo] = .focusWorkspace(i)
      }
    }

    // Move to workspace (1..9)
    for i in 1...9 {
      if let combo = KeyCombo.parse("ctrl+alt+shift+\(i)") {
        bindings[combo] = .moveToWorkspace(i)
      }
    }

    // Column width
    bindings[.parse("ctrl+alt+comma")!] = .decreaseColumnWidth
    bindings[.parse("ctrl+alt+period")!] = .increaseColumnWidth

    // Misc
    bindings[.parse("ctrl+alt+t")!] = .toggleColumnTabbed
    bindings[.parse("ctrl+alt+q")!] = .closeWindow
    bindings[.parse("ctrl+alt+bracketleft")!] = .consumeOrExpelLeft
    bindings[.parse("ctrl+alt+bracketright")!] = .consumeOrExpelRight
    bindings[.parse("ctrl+alt+f")!] = .toggleFloat

    // Screen focus
    bindings[.parse("ctrl+alt+p")!] = .focusScreenPrevious
    bindings[.parse("ctrl+alt+n")!] = .focusScreenNext

    // Move to screen
    bindings[.parse("ctrl+alt+shift+p")!] = .moveToScreenPrevious
    bindings[.parse("ctrl+alt+shift+n")!] = .moveToScreenNext

    return bindings
  }
}
