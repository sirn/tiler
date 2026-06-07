import AppKit
import ApplicationServices
import Darwin

public enum TilerEvent {
  case appLaunched(pid_t)
  case appTerminated(pid_t)
  case windowCreated(AXUIElement)
  case windowDestroyed(AXUIElement)
  case windowMinimized
  case windowDeminimized
  case focusChanged(pid_t, AXUIElement)
  case geometryChanged(pid_t, AXUIElement)
}

public class EventBroker {
  public var onEvent: ((TilerEvent) -> Void)?

  private var appObservers: [pid_t: AppObserver] = [:]
  private var observers: [NSObjectProtocol] = []
  private var started = false

  public init() {}

  public func start() {
    guard !started else { return }
    started = true
    let nc = NSWorkspace.shared.notificationCenter

    observers.append(
      nc.addObserver(
        forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let self = self else { return }
        guard
          let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
          app.activationPolicy == .regular
        else { return }
        let pid = app.processIdentifier
        self.registerAppObserver(pid: pid)
        self.onEvent?(.appLaunched(pid))
      })

    observers.append(
      nc.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let self = self else { return }
        guard
          let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        else { return }
        let pid = app.processIdentifier
        self.appObservers.removeValue(forKey: pid)
        self.onEvent?(.appTerminated(pid))
      })

    // Register for already-running apps
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
      registerAppObserver(pid: app.processIdentifier)
    }
  }

  public func stop() {
    for obs in observers {
      NSWorkspace.shared.notificationCenter.removeObserver(obs)
    }
    observers.removeAll()
    appObservers.removeAll()
    started = false
  }

  private func registerAppObserver(pid: pid_t) {
    guard appObservers[pid] == nil else { return }

    let observer = AppObserver(pid: pid) { [weak self] _, element, notification in
      guard let self = self else { return }

      let notifStr = notification as String
      if tilerDebugEnabled {
        let nwid = axGetWindowID(element) ?? 0
        let napp = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        tiler_debug("event: \(notifStr) pid=\(pid) app=\(napp) wid=\(nwid)")
      }

      if notifStr == kAXFocusedWindowChangedNotification as String {
        self.onEvent?(.focusChanged(pid, element))
      } else if notifStr == kAXWindowCreatedNotification as String {
        self.onEvent?(.windowCreated(element))
      } else if notifStr == kAXUIElementDestroyedNotification as String {
        self.onEvent?(.windowDestroyed(element))
      } else if notifStr == kAXWindowMiniaturizedNotification as String {
        self.onEvent?(.windowMinimized)
      } else if notifStr == kAXWindowDeminiaturizedNotification as String {
        self.onEvent?(.windowDeminimized)
      } else if notifStr == kAXWindowMovedNotification as String
        || notifStr == kAXWindowResizedNotification as String
      {
        self.onEvent?(.geometryChanged(pid, element))
      }
    }

    if let observer = observer {
      appObservers[pid] = observer
    }
  }

  deinit {
    stop()
  }
}
