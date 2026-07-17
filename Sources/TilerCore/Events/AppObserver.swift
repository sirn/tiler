import AppKit
import ApplicationServices

/// Manages AXObserver for a single app process.
public class AppObserver {
  public let pid: pid_t
  private var observer: AXObserver?

  public typealias EventCallback = (AXObserver, AXUIElement, CFString) -> Void

  public init?(pid: pid_t, callback: @escaping EventCallback) {
    self.pid = pid
    self.externalCallback = callback

    var obs: AXObserver?
    let status = AXObserverCreate(
      pid,
      { (obs, element, notification, refcon) in
        guard let refcon = refcon else { return }
        let unmanaged = Unmanaged<AppObserver>.fromOpaque(refcon)
        unmanaged.takeUnretainedValue().handleEvent(
          observer: obs, element: element, notification: notification)
      }, &obs)

    guard status == .success, let observer = obs else { return nil }
    self.observer = observer

    // Store self reference in callback refcon
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()

    let notifications: [CFString] = [
      kAXWindowCreatedNotification as CFString,
      kAXUIElementDestroyedNotification as CFString,
      kAXWindowMovedNotification as CFString,
      kAXWindowResizedNotification as CFString,
      kAXFocusedWindowChangedNotification as CFString,
      kAXWindowMiniaturizedNotification as CFString,
      kAXWindowDeminiaturizedNotification as CFString,
    ]

    let criticalNotifications: Set<CFString> = [
      kAXWindowCreatedNotification as CFString,
      kAXUIElementDestroyedNotification as CFString,
    ]

    // AXObserverAddNotification can block for seconds on an unresponsive app
    // (Phoenix #114). Subscribe on a utility queue so a hung process can't freeze
    // the main run loop; events arriving before subscription completes are
    // recovered by the periodic CGWindowList reconcile. The run-loop source is
    // attached below on the main thread so deinit can remove it deterministically.
    // Strong-capture self so it outlives subscription. selfPtr is an unretained
    // refcon; a [weak self] guard only checks liveness at entry, so if self deinits
    // mid-loop AXObserverAddNotification would store a dangling refcon and crash
    // when an event later dereferences it.
    AppObserver.subscriptionQueue.async { [self] in
      for notification in notifications {
        let err = AXObserverAddNotification(
          observer, AXUIElementCreateApplication(pid), notification, selfPtr)
        if err != .success {
          if criticalNotifications.contains(notification) {
            tiler_log(
              "Warning - critical notification \(notification) subscription failed for PID \(pid): \(err.rawValue)"
            )
          } else {
            tiler_log(
              "Warning - could not subscribe to \(notification) for PID \(pid): \(err.rawValue)")
          }
        }
      }
    }

    // Add observer to run loop
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
  }

  // Concurrent utility queue: each app subscribes independently so one hung
  // process can't stall subscription for the others.
  private static let subscriptionQueue = DispatchQueue(
    label: "co.cakework.Tiler.ax-subscription", qos: .utility, attributes: .concurrent)

  private var externalCallback: EventCallback?

  private func handleEvent(observer: AXObserver, element: AXUIElement, notification: CFString) {
    externalCallback?(observer, element, notification)
  }

  deinit {
    if let observer = observer {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
  }
}
