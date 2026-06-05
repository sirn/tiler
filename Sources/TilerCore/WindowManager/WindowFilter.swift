import AppKit
import ApplicationServices

public enum WindowFilter {
    public static func isTileable(_ element: AXUIElement) -> Bool {
        // Check role
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let roleStr = role as? String, roleStr == kAXWindowRole else {
            return false
        }

        // Check subrole - allow standard windows, dialogs, and unknown subroles
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let subroleStr = subrole as? String {
            // Reject only known-non-tileable subroles
            switch subroleStr {
            case "AXSheet", "AXDrawer", "AXSystemDialog":
                return false
            default:
                break
            }
        }

        // Check minimized
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized) == .success,
           let minimizedBool = minimized as? Bool, minimizedBool {
            return false
        }

        // Check fullscreen
        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &fullScreen) == .success,
           let fullScreenBool = fullScreen as? Bool, fullScreenBool {
            return false
        }

        // Get PID from the element's parent app
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        // Check that the app is a regular app
        if let app = NSRunningApplication(processIdentifier: pid) {
            guard app.activationPolicy == .regular else {
                return false
            }
        }

        return true
    }
}
