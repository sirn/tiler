import AppKit
import ApplicationServices

public enum TilerEvent {
    case windowCreated(CGWindowID, AXUIElement, pid_t)
    case windowDestroyed(CGWindowID, pid_t)
    case windowMoved(CGWindowID, pid_t)
    case windowResized(CGWindowID, pid_t)
    case windowFocused(CGWindowID?, pid_t)
    case windowMiniaturized(CGWindowID, pid_t)
    case windowDeminiaturized(CGWindowID, pid_t)
    case appLaunched(pid_t)
    case appTerminated(pid_t)
    case appActivated(pid_t)
}

/// Central event hub: subscribes to NSWorkspace + per-app AX observers,
/// normalizes everything into TilerEvent values.
public class EventBroker {
    public typealias EventHandler = (TilerEvent) -> Void

    private var appObservers: [pid_t: AppObserver] = [:]
    private var eventHandler: EventHandler?
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public func setEventHandler(_ handler: @escaping EventHandler) {
        self.eventHandler = handler
    }

    public func start() {
        let nc = NSWorkspace.shared.notificationCenter

        // App launch
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let pid = app.processIdentifier as pid_t? else { return }
            self?.handleAppLaunched(pid: pid)
        })

        // App terminate
        observers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let pid = app.processIdentifier as pid_t? else { return }
            self?.handleAppTerminated(pid: pid)
        })

        // App activate
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let pid = app.processIdentifier as pid_t? else { return }
            self?.emit(.appActivated(pid))
        })

        // Enumerate already-running apps
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            handleAppLaunched(pid: app.processIdentifier)
        }
    }

    public func stop() {
        for obs in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        observers.removeAll()
        appObservers.removeAll()
    }

    private func handleAppLaunched(pid: pid_t) {
        print("tiler: App launched: \(pid)")
        emit(.appLaunched(pid))

        guard appObservers[pid] == nil else { return }

        let observer = AppObserver(pid: pid) { [weak self] _, element, notification in
            self?.handleAXNotification(element: element, notification: notification, pid: pid)
        }

        if let observer = observer {
            appObservers[pid] = observer
        }
    }

    private func handleAppTerminated(pid: pid_t) {
        print("tiler: App terminated: \(pid)")
        appObservers.removeValue(forKey: pid)
        emit(.appTerminated(pid))
    }

    private func handleAXNotification(element: AXUIElement, notification: CFString, pid: pid_t) {
        switch notification as String {
        case kAXWindowCreatedNotification as String:
            if let (winID, _) = findWindowInfo(element: element, pid: pid) {
                emit(.windowCreated(winID, element, pid))
            }

        case kAXUIElementDestroyedNotification as String:
            // We don't have the window ID anymore since it's destroyed
            // The WindowManager will clean up based on pid + blind removal
            emit(.windowDestroyed(0, pid))

        case kAXWindowMovedNotification as String:
            if let (winID, _) = findWindowInfo(element: element, pid: pid) {
                emit(.windowMoved(winID, pid))
            }

        case kAXWindowResizedNotification as String:
            if let (winID, _) = findWindowInfo(element: element, pid: pid) {
                emit(.windowResized(winID, pid))
            }

        case kAXWindowMiniaturizedNotification as String:
            if let (winID, _) = findWindowInfo(element: element, pid: pid) {
                emit(.windowMiniaturized(winID, pid))
            }

        case kAXWindowDeminiaturizedNotification as String:
            if let (winID, _) = findWindowInfo(element: element, pid: pid) {
                emit(.windowDeminiaturized(winID, pid))
            }

        default:
            break
        }
    }

    private func emit(_ event: TilerEvent) {
        DispatchQueue.main.async {
            self.eventHandler?(event)
        }
    }

    /// Helper to look up CGWindowID and title for an AXUIElement
    private func findWindowInfo(element: AXUIElement, pid: pid_t) -> (CGWindowID, String)? {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Get the position and size of this AX window
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success else {
            return nil
        }

        var point = CGPoint.zero
        var dimensions = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &dimensions)

        for info in windowInfo {
            guard let infoPID = info[kCGWindowOwnerPID as String] as? pid_t, infoPID == pid else { continue }
            guard let windowNumber = info[kCGWindowNumber as String] as? CGWindowID else { continue }

            // Match by PID and approximate position
            if let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] {
                let wx = boundsDict["X"] ?? 0
                let wy = boundsDict["Y"] ?? 0
                let ww = boundsDict["Width"] ?? 0
                let wh = boundsDict["Height"] ?? 0

                if abs(wx - point.x) < 1 && abs(wy - point.y) < 1 &&
                   abs(ww - dimensions.width) < 1 && abs(wh - dimensions.height) < 1 {
                    let title = info[kCGWindowName as String] as? String ?? ""
                    return (windowNumber, title)
                }
            }
        }
        return nil
    }
}
