import AppKit
import ApplicationServices
import TilerCore

class AppDelegate: NSObject, NSApplicationDelegate {
  private var eventBroker: EventBroker?
  private var windowManager: WindowManager?
  private var hotkeyDispatcher: HotkeyDispatcher?
  private var configLoader: ConfigLoader?
  private var statusBar: StatusBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Ensure accessibility permissions are granted
    guard AXIsProcessTrusted() else {
      let options: NSDictionary = [
        kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true
      ]
      _ = AXIsProcessTrustedWithOptions(options)
      tiler_log(
        "Accessibility permission required. Please grant it in System Settings > Privacy & Security > Accessibility, then relaunch."
      )
      NSApplication.shared.terminate(nil)
      return
    }
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

    // Initialize screens and workspaces
    wm.initializeScreens()

    // Menu bar workspace indicator
    let statusBar = StatusBarController()
    self.statusBar = statusBar
    if let indicator = wm.workspaceIndicator() {
      statusBar.update(occupied: indicator.occupied, current: indicator.current)
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

  func applicationWillTerminate(_ notification: Notification) {
    windowManager?.saveState()
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

    // Screen focus
    bindings[.parse("ctrl+alt+p")!] = .focusScreenLeft
    bindings[.parse("ctrl+alt+n")!] = .focusScreenRight

    // Move to screen
    bindings[.parse("ctrl+alt+shift+p")!] = .moveToScreenLeft
    bindings[.parse("ctrl+alt+shift+n")!] = .moveToScreenRight

    return bindings
  }
}
