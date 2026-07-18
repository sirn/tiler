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

    var subrole: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
      == .success,
      let subroleStr = subrole as? String
    {
      switch subroleStr {
      case "AXSheet", "AXDrawer", "AXSystemDialog", "AXFloatingWindow", "Quick Look":
        return false
      case "AXStandardWindow":
        // Standard windows should have a close button. macOS file dialogs (Open/Save
        // panels promoted to standalone windows in newer OS versions) report
        // AXStandardWindow but lack a close button — reject them.
        var closeButton: CFTypeRef?
        guard
          AXUIElementCopyAttributeValue(
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
        guard
          AXUIElementCopyAttributeValue(
            element, kAXCloseButtonAttribute as CFString, &closeButton
          ) == .success, closeButton != nil
        else {
          return false
        }
      }
    } else {
      return false
    }

    var minimized: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
      == .success,
      let minimizedBool = minimized as? Bool, minimizedBool
    {
      return false
    }

    var fullScreen: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &fullScreen) == .success,
      let fullScreenBool = fullScreen as? Bool, fullScreenBool
    {
      return false
    }

    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return false }
    guard let app = NSRunningApplication(processIdentifier: pid),
      app.activationPolicy == .regular
    else { return false }

    return true
  }

  /// True when the window is in native macOS fullscreen (its own dedicated Space).
  /// Used to detect that the regular Space is hidden, so windows absent from the
  /// on-screen CGWindowList are merely on the hidden Space rather than gone.
  public static func isFullscreen(_ element: AXUIElement) -> Bool {
    var fullScreen: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &fullScreen)
      == .success && (fullScreen as? Bool) == true
  }
}
