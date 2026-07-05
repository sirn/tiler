import AppKit
import ApplicationServices

public enum WindowFilter {
  public static func isTileable(_ element: AXUIElement) -> Bool {
    // Check role. Emacs's NS port reports its main window with role AXTextField
    // instead of AXWindow; accept it here and rely on the subrole + close-button
    // checks below to confirm it is a genuine window.
    var role: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
      let roleStr = role as? String,
      roleStr == kAXWindowRole || roleStr == "AXTextField"
    else {
      return false
    }

    // Check subrole - allow standard windows, dialogs, and unknown subroles
    var subrole: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
      == .success,
      let subroleStr = subrole as? String
    {
      // Reject known-non-tileable subroles
      switch subroleStr {
      case "AXSheet", "AXDrawer", "AXSystemDialog", "AXFloatingWindow", "Quick Look":
        return false
      case "AXStandardWindow":
        // Standard windows should have a close button. macOS file dialogs (Open/Save
        // panels promoted to standalone windows in newer OS versions) report
        // AXStandardWindow but lack a close button — reject them.
        var closeButton: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
          element, kAXCloseButtonAttribute as CFString, &closeButton
        ) == .success, closeButton != nil
        else {
          return false
        }
      default:
        // Non-standard subrole (AXDialog, AXUnknown, etc.) — require a close button
        // to confirm it's a genuine window with standard chrome. This rejects
        // Chromium extension popups which have AXUnknown subrole and no window
        // buttons.
        var closeButton: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
          element, kAXCloseButtonAttribute as CFString, &closeButton
        ) == .success, closeButton != nil
        else {
          return false
        }
      }
    }

    // Check minimized
    var minimized: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
      == .success,
      let minimizedBool = minimized as? Bool, minimizedBool
    {
      return false
    }

    // Check fullscreen
    var fullScreen: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &fullScreen) == .success,
      let fullScreenBool = fullScreen as? Bool, fullScreenBool
    {
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
